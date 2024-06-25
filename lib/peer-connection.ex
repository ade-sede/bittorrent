defmodule Bittorrent.PeerConnection do
  use GenServer
  alias Bittorrent.Protocol

  defstruct socket: nil,
            peer_id: nil,
            queue: nil,
            block: nil,
            is_choked: true,
            interested_flag: false,
            bitfield: nil

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  def init({peer_address, info_hash, client_id, queue}) do
    IO.puts("Initializing peer connection")

    case Protocol.handshake(peer_address, info_hash, client_id) do
      {:error, reason} ->
        IO.puts(reason)
        # we don't mind if some of the peers are not responding as long as some of them are
        :ignore

      {socket, peer_id} ->
        IO.puts("Established connection to peer #{peer_id}")
        :inet.setopts(socket, active: :once)

        initial_state =
          %Bittorrent.PeerConnection{
            socket: socket,
            peer_id: peer_id,
            queue: queue
          }

        {:ok, initial_state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    IO.puts("Connection to peer #{state.peer_id} has been closed")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    case Protocol.parse_message(data) do
      :keep_alive ->
        :inet.setopts(socket, active: :once)
        {:noreply, state}

      # A message may exceed a tcp segment
      {:incomplete, n} ->
        case :gen_tcp.recv(socket, n) do
          {:error, reason} ->
            {:stop, reason}

          {:ok, packet} ->
            :inet.setopts(socket, active: :once)
            handle_info({:tcp, socket, data <> packet}, state)
        end

      {:unknown, _} ->
        {:stop, "Received unsupported message type"}

      {message_id, payload} ->
        :inet.setopts(socket, active: :once)
        GenServer.cast(self(), {message_id, payload})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:choke, _}, state) do
    IO.puts("Peer #{state.peer_id} is choked")
    {:noreply, %{state | is_choked: true}}
  end

  @impl true
  def handle_cast({:unchoke, _}, state) do
    IO.puts("Peer #{state.peer_id} is unchoked")
    GenServer.cast(self(), :request_block)
    {:noreply, %{state | is_choked: false}}
  end

  @impl true
  def handle_cast({:bitfield, payload}, state) do
    IO.puts("Received bitfield: #{inspect(payload)}")
    GenServer.cast(self(), :start_download)
    {:noreply, %{state | bitfield: payload}}
  end

  @impl true
  def handle_cast({:piece, payload}, state) do
    <<piece_index::32, block_offset::32, data::binary>> = payload

    {_, expected_block_index, _, expected_block_size} =
      state.block

    IO.puts("Received piece: index #{piece_index}, block #{expected_block_index}")

    GenServer.call(
      state.queue,
      {:downloaded, {piece_index, expected_block_index, block_offset, expected_block_size, data}}
    )

    GenServer.cast(self(), :start_download)
    {:noreply, %{state | block: nil}}
  end

  @impl true
  def handle_cast(:request_block, state) do
    IO.puts("Requesting block")

    case {state.is_choked, state.block} do
      {true, _} ->
        {:stop, "Currently chocked"}

      {_, nil} ->
        {:stop, "No block set to download"}

      {_, {piece_index, _block_index, block_offset, block_size}} ->
        request_message =
          <<0, 0, 0, 13, 6, piece_index::32, block_offset::32, block_size::32>>

        case :gen_tcp.send(state.socket, request_message) do
          {:error, reason} ->
            {:stop, reason}

          :ok ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast(:start_download, state) do
    case GenServer.call(state.queue, :get_one_to_download) do
      nil ->
        case :gen_tcp.send(state.socket, <<0, 0, 0, 1, 3>>) do
          {:error, reason} ->
            {:stop, reason}

          :ok ->
            {:noreply, %{state | interested_flag: false}}
        end

      block ->
        case state.interested_flag do
          false ->
            case :gen_tcp.send(state.socket, <<0, 0, 0, 1, 2>>) do
              {:error, reason} ->
                {:stop, reason}

              :ok ->
                {:noreply, %{state | block: block, interested_flag: true}}
            end

          true ->
            case state.is_choked do
              false ->
                GenServer.cast(self(), :request_block)
                {:noreply, %{state | block: block}}

              true ->
                {:noreply, %{state | block: block}}
            end
        end
    end
  end

  @impl true
  def handle_cast({message_id, _}, _) do
    {:stop, "Received unsupported message ID #{message_id}"}
  end
end
