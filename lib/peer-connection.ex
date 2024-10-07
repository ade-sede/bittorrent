defmodule Bittorrent.PeerConnection do
  use GenServer
  require Bittorrent.Protocol
  alias Bittorrent.Protocol
  alias Bittorrent.PeerState

  @max_concurrent_requests 10

  defstruct [
    :socket,
    :peer_state,
    :info_hash,
    :client_id,
    :extensions,
    :queue,
    :max_block_length,
    :color
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({peer_address, info_hash, client_id, queue, max_block_length, color}) do
    case Protocol.handshake(peer_address, info_hash, client_id) do
      {:error, reason} ->
        log(color, "Failed handshake with peer #{peer_address}: #{reason}")
        :ignore

      {socket, peer_id, extensions} ->
        :inet.setopts(socket, active: :once)
        log(color, "Connected to peer: #{peer_address}")

        state = %__MODULE__{
          socket: socket,
          peer_state: PeerState.new(peer_id),
          info_hash: info_hash,
          client_id: client_id,
          extensions: extensions,
          queue: queue,
          max_block_length: max_block_length,
          color: color
        }

        {:ok, state, {:continue, :request_bitfield}}
    end
  end

  @impl true
  def handle_continue(:request_bitfield, state) do
    log(state.color, "Sending interested message")

    case send_message(state.socket, :interested, state.color) do
      {:error, reason} ->
        log(state.color, "Error when sending interested flag: #{reason}")
        {:stop, reason}

      _ ->
        new_peer_state = PeerState.am_interested(state.peer_state)
        {:noreply, %{state | peer_state: new_peer_state}}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    log(state.color, "Received TCP data: #{inspect(data, limit: 50)}")
    new_state = handle_message(data, state)
    :inet.setopts(socket, active: :once)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    log(state.color, "Connection closed")
    {:stop, :normal, state}
  end

  defp handle_message(data, state) do
    case Protocol.decode_message(data) do
      :keep_alive ->
        log(state.color, "Received keep-alive")
        state

      {:bitfield, payload} ->
        log(state.color, "Received bitfield: #{inspect(payload, limit: 50)}")
        new_peer_state = PeerState.set_piece_availability(state.peer_state, payload)
        new_state = %{state | peer_state: new_peer_state}

        if MapSet.member?(new_state.extensions, Protocol.extension_protocol()) do
          log(new_state.color, "Peer supports extension protocol !")

          send_message(
            new_state.socket,
            {:extension,
             %{
               "m" => %{
                 ut_metadata: 999
               }
             }},
            new_state.color
          )
        end

        request_pieces(new_state)

      {:unchoke, _} ->
        log(state.color, "Peer unchoked us")
        new_peer_state = PeerState.peer_unchoke(state.peer_state)
        new_state = %{state | peer_state: new_peer_state}
        request_pieces(new_state)

      {:choke, _} ->
        log(state.color, "Peer choked us")
        new_peer_state = PeerState.peer_choke(state.peer_state)
        %{state | peer_state: new_peer_state}

      {:have, <<piece::32>>} ->
        log(state.color, "Peer has piece #{piece}")
        new_peer_state = PeerState.update_available_piece(state.peer_state, piece)
        new_state = %{state | peer_state: new_peer_state}
        maybe_request_piece(new_state, piece)

      {:piece, <<index::32, begin::32, block::binary>>} ->
        log(state.color, "Received piece #{index}, offset #{begin}, length #{byte_size(block)}")
        new_state = handle_received_piece(state, index, begin, block)
        request_pieces(new_state)

      {:reject_request, index, begin, length} ->
        log(
          state.color,
          "Peer rejected request for piece #{index}, offset #{begin}, length #{length}"
        )

        new_peer_state = PeerState.remove_request(state.peer_state, index, begin)
        GenServer.call(state.queue, {:reset_block, index, begin, length})
        new_state = %{state | peer_state: new_peer_state}
        request_pieces(new_state)

      {:incomplete, missing} ->
        log(state.color, "Missing bytes count: #{missing}")

        case :gen_tcp.recv(state.socket, missing) do
          {:error, reason} ->
            log(:red, "Error while receiving remainder of message: #{reason}")
            {:stop, reason}

          {:ok, remaining_data} ->
            log(state.color, "Collected missing data: #{byte_size(remaining_data)}")
            handle_message(data <> remaining_data, state)
        end

      msg ->
        log(state.color, "Received unknown message: #{inspect(msg)}")
        state
    end
  end

  defp maybe_request_piece(state, piece) do
    if PeerState.can_request?(state.peer_state, @max_concurrent_requests) do
      case GenServer.call(state.queue, {:need_piece?, piece}) do
        true ->
          log(state.color, "Requesting specific piece #{piece}")
          request_specific_piece(state, piece)

        false ->
          log(state.color, "Piece #{piece} not needed")
          state
      end
    else
      log(state.color, "Cannot request more pieces at the moment")
      state
    end
  end

  defp request_pieces(state) do
    available_slots = @max_concurrent_requests - PeerState.request_count(state.peer_state)
    log(state.color, "Requesting pieces, available slots: #{available_slots}")

    Enum.reduce_while(1..available_slots, state, fn _, acc ->
      if PeerState.can_request?(acc.peer_state, @max_concurrent_requests) do
        case GenServer.call(acc.queue, :get_block_to_download) do
          nil ->
            log(acc.color, "No more blocks to download")
            new_peer_state = PeerState.am_not_interested(state.peer_state)
            {:halt, %{acc | peer_state: new_peer_state}}

          {piece_index, block_offset, block_length} ->
            log(
              acc.color,
              "Requesting piece #{piece_index}, offset #{block_offset}, length #{block_length}"
            )

            new_peer_state =
              PeerState.add_request(acc.peer_state, piece_index, block_offset, block_length)

            new_state = %{acc | peer_state: new_peer_state}

            send_message(
              new_state.socket,
              {:request, piece_index, block_offset, block_length},
              new_state.color
            )

            {:cont, new_state}
        end
      else
        log(acc.color, "Cannot request more pieces")
        {:halt, acc}
      end
    end)
  end

  defp request_specific_piece(state, piece_index) do
    case GenServer.call(state.queue, {:get_block, piece_index}) do
      nil ->
        log(state.color, "No blocks available for piece #{piece_index}")
        state

      {block_offset, block_length} ->
        log(
          state.color,
          "Requesting specific piece #{piece_index}, offset #{block_offset}, length #{block_length}"
        )

        new_peer_state =
          PeerState.add_request(state.peer_state, piece_index, block_offset, block_length)

        new_state = %{state | peer_state: new_peer_state}

        send_message(
          new_state.socket,
          {:request, piece_index, block_offset, block_length},
          new_state.color
        )

        new_state
    end
  end

  defp handle_received_piece(state, index, begin, block) do
    new_peer_state = PeerState.remove_request(state.peer_state, index, begin)
    new_state = %{state | peer_state: new_peer_state}

    GenServer.call(state.queue, {:block_received, index, begin, block})

    request_pieces(new_state)
  end

  defp send_message(socket, message, color) do
    case Protocol.encode_message(message) do
      {:ok, encoded} ->
        result = :gen_tcp.send(socket, encoded)
        log(color, "Sent message: #{inspect(message)}, result: #{inspect(result)}")
        result

      {:error, reason} ->
        log(color, "Failed to encode message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp log(color, message) do
    IO.puts(IO.ANSI.format([color, "#{inspect(self())} - #{message}", :reset]))
  end
end
