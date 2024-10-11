defmodule Bittorrent.PeerConnection do
  use GenServer
  alias Bittorrent.Protocol
  alias Bittorrent.Bencode
  alias Bittorrent.PeerState

  @max_concurrent_requests 1
  @self_metadata_extension_id 100

  defstruct [
    :socket,
    :peer_state,
    :info_hash,
    :client_id,
    :queue,
    :parent,
    :info_logger,
    :error_logger
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({peer_address, info_hash, client_id, parent, queue, extensions, logger}) do
    {info_logger, error_logger} = logger

    case Protocol.handshake(peer_address, info_hash, client_id, extensions) do
      {:error, reason} ->
        error_logger.("Failed handshake with peer #{peer_address}: #{reason}")
        :ignore

      {socket, peer_id, extensions} ->
        :inet.setopts(socket, active: :once)
        info_logger.("Connected to peer: #{peer_address}")

        state = %__MODULE__{
          socket: socket,
          peer_state: PeerState.new(peer_id, extensions),
          info_hash: info_hash,
          client_id: client_id,
          queue: queue,
          parent: parent,
          info_logger: info_logger,
          error_logger: error_logger
        }

        send(state.parent, {self(), :peer_id, peer_id})

        {:ok, state}
    end
  end

  @impl true
  def handle_call(:request_metadata, _from, state) do
    Enum.each(0..(state.peer_state.number_expected_metadata_pieces - 1), fn piece_index ->
      send_message(state, {
        :request_metadata,
        piece_index,
        state.peer_state.metadata_extension_id
      })
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:new_downloads_available, state) do
    case interested(state) do
      {:error, reason} ->
        state.error_logger.(reason)

      {atom, state} when atom in [:noop, :ok] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    state.info_logger.("Received TCP data: #{inspect(data, limit: 50)}")
    new_state = handle_message(data, state)
    :inet.setopts(socket, active: :once)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    state.info_logger.("Connection closed")
    {:stop, :normal, state}
  end

  defp interested(state) do
    case GenServer.call(state.queue, :available_to_download?) do
      true ->
        state.info_logger.("Sending interested message")

        case send_message(state, :interested) do
          {:error, reason} ->
            {:error, "Error when sending interested flag: #{reason}"}

          _ ->
            new_peer_state = PeerState.am_interested(state.peer_state)
            {:ok, %{state | peer_state: new_peer_state}}
        end

      false ->
        {:noop, state}
    end
  end

  defp handle_message(data, state) do
    msg = Protocol.decode_message(data)

    case msg do
      :keep_alive ->
        state.info_logger.("Received keep-alive")
        state

      {:overflow, msg, rest} ->
        new_state = _apply(msg, data, state)
        handle_message(rest, new_state)

      {:reject_request, _, _, _} ->
        _apply(msg, data, state)

      {{:unknown, _id}, _} ->
        state.info_logger.("Received unknown message: #{inspect(msg)}")
        state

      {_, _} ->
        _apply(msg, data, state)
    end
  end

  defp _apply(msg, data, state) do
    case msg do
      {:bitfield, payload} ->
        state.info_logger.("Received bitfield: #{inspect(payload, limit: 50)}")
        peer_state = PeerState.set_piece_availability(state.peer_state, payload)
        state = %{state | peer_state: peer_state}

        if PeerState.extension_protocol_enabled?(state.peer_state) do
          state.info_logger.("Peer supports extension protocol !")

          send_message(state, {
            :extension,
            %{
              "m" => %{
                "ut_metadata" => @self_metadata_extension_id
              }
            }
          })

          send(state.parent, {self(), :extension_handshake_sent})
        end

        case interested(state) do
          {:error, reason} ->
            state.error_logger.(reason)

          {atom, state} when atom in [:ok, :noop] ->
            state
        end

      {:unchoke, _} ->
        state.info_logger.("Peer unchoked us")
        new_peer_state = PeerState.peer_unchoke(state.peer_state)
        new_state = %{state | peer_state: new_peer_state}
        request_pieces(new_state)

      {:choke, _} ->
        state.info_logger.("Peer choked us")
        new_peer_state = PeerState.peer_choke(state.peer_state)
        %{state | peer_state: new_peer_state}

      {:have, <<piece::32>>} ->
        state.info_logger.("Peer has piece #{piece}")
        new_peer_state = PeerState.update_available_piece(state.peer_state, piece)
        new_state = %{state | peer_state: new_peer_state}
        maybe_request_piece(new_state, piece)

      {:piece, <<index::32, begin::32, block::binary>>} ->
        state.info_logger.("Received piece #{index}, offset #{begin}, length #{byte_size(block)}")
        new_state = handle_received_piece(state, index, begin, block)
        request_pieces(new_state)

      {:reject_request, index, begin, length} ->
        state.info_logger.(
          "Peer rejected request for piece #{index}, offset #{begin}, length #{length}"
        )

        new_peer_state = PeerState.remove_request(state.peer_state, index, begin)
        GenServer.call(state.queue, {:reset_block, index, begin, length})
        new_state = %{state | peer_state: new_peer_state}
        request_pieces(new_state)

      {:extension, extension} ->
        case extension do
          {:handshake, dict} ->
            {dict, _} = Bencode.decode(dict)

            peer_state =
              PeerState.set_metadata_info(
                state.peer_state,
                dict["m"]["ut_metadata"],
                dict["metadata_size"]
              )

            send(
              state.parent,
              {self(), :peer_ut_metadata,
               {peer_state.metadata_length, peer_state.metadata_extension_id}}
            )

            %{state | peer_state: peer_state}

          {{:unknown, id}, payload} ->
            if id == @self_metadata_extension_id do
              {dict, metadata} = Bencode.decode(payload)

              if dict["total_size"] != byte_size(metadata) do
                state.error_logger.("Incomplete metadata")
              end

              peer_state =
                PeerState.append_metadata_piece(state.peer_state, metadata)

              if peer_state.number_received_metadata_pieces ==
                   peer_state.number_expected_metadata_pieces do
                send(
                  state.parent,
                  {self(), :received_all_metadata, peer_state.metadata_pieces}
                )
              end

              %{state | peer_state: peer_state}
            else
              state.error_logger.("Unknown extension messages")
            end
        end

      {:incomplete, missing} ->
        state.info_logger.("Missing bytes count: #{missing}")

        case :gen_tcp.recv(state.socket, missing) do
          {:error, reason} ->
            state.error_logger.("Error while receiving remainder of message: #{reason}")

          {:ok, remaining_data} ->
            state.info_logger.("Collected missing data: #{byte_size(remaining_data)}")
            handle_message(data <> remaining_data, state)
        end
    end
  end

  defp maybe_request_piece(state, piece) do
    if PeerState.can_request?(state.peer_state, @max_concurrent_requests) do
      case GenServer.call(state.queue, {:need_piece?, piece}) do
        true ->
          state.info_logger.("Requesting specific piece #{piece}")
          request_specific_piece(state, piece)

        false ->
          state.info_logger.("Piece #{piece} not needed")
          state
      end
    else
      state.info_logger.("Cannot request more pieces at the moment")
      state
    end
  end

  defp request_pieces(state) do
    available_slots = @max_concurrent_requests - PeerState.request_count(state.peer_state)
    state.info_logger.("Requesting pieces, available slots: #{available_slots}")

    Enum.reduce_while(1..available_slots, state, fn _, acc ->
      if PeerState.can_request?(acc.peer_state, @max_concurrent_requests) do
        case GenServer.call(acc.queue, :get_block_to_download) do
          nil ->
            state.info_logger.("No more blocks to download")
            new_peer_state = PeerState.am_not_interested(state.peer_state)
            {:halt, %{acc | peer_state: new_peer_state}}

          {piece_index, block_offset, block_length} ->
            state.info_logger.(
              "Requesting piece #{piece_index}, offset #{block_offset}, length #{block_length}"
            )

            new_peer_state =
              PeerState.add_request(acc.peer_state, piece_index, block_offset, block_length)

            new_state = %{acc | peer_state: new_peer_state}

            send_message(new_state, {:request, piece_index, block_offset, block_length})

            {:cont, new_state}
        end
      else
        state.info_logger.("Cannot request more pieces")
        {:halt, acc}
      end
    end)
  end

  defp request_specific_piece(state, piece_index) do
    case GenServer.call(state.queue, {:get_block, piece_index}) do
      nil ->
        state.info_logger.("No blocks available for piece #{piece_index}")
        state

      {block_offset, block_length} ->
        state.info_logger.(
          "Requesting specific piece #{piece_index}, offset #{block_offset}, length #{block_length}"
        )

        new_peer_state =
          PeerState.add_request(state.peer_state, piece_index, block_offset, block_length)

        new_state = %{state | peer_state: new_peer_state}

        send_message(new_state, {:request, piece_index, block_offset, block_length})

        new_state
    end
  end

  defp handle_received_piece(state, index, begin, block) do
    new_peer_state = PeerState.remove_request(state.peer_state, index, begin)
    new_state = %{state | peer_state: new_peer_state}

    GenServer.call(state.queue, {:block_received, index, begin, block})

    request_pieces(new_state)
  end

  defp send_message(state, message) do
    case Protocol.encode_message(message) do
      {:ok, encoded} ->
        result = :gen_tcp.send(state.socket, encoded)
        state.info_logger.("Sent message: #{inspect(message)}, result: #{inspect(result)}")
        result

      {:error, reason} ->
        state.info_logger.("Failed to encode message: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
