defmodule Bittorrent.PeerState do
  import Bitwise

  defstruct [
    :peer_id,
    :available_pieces,
    :peer_choking,
    :am_interested,
    :active_requests
  ]

  def new(peer_id) do
    %__MODULE__{
      peer_id: peer_id,
      available_pieces: MapSet.new(),
      peer_choking: true,
      am_interested: false,
      active_requests: %{}
    }
  end

  def update_available_piece(state, piece_index) do
    %{state | available_pieces: MapSet.put(state.available_pieces, piece_index)}
  end

  def set_piece_availability(state, bitfield) do
    available =
      bitfield
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {byte, byte_index} ->
        0..7
        |> Enum.filter(fn bit -> (byte &&& 1 <<< (7 - bit)) != 0 end)
        |> Enum.map(fn bit -> byte_index * 8 + bit end)
      end)

    %{state | available_pieces: MapSet.new(available)}
  end

  def peer_choke(state), do: %{state | peer_choking: true}
  def peer_unchoke(state), do: %{state | peer_choking: false}

  def am_interested(state), do: %{state | am_interested: true}
  def am_not_interested(state), do: %{state | am_interested: false}

  def add_request(state, piece_index, begin, length) do
    new_requests = Map.put(state.active_requests, {piece_index, begin}, length)
    %{state | active_requests: new_requests}
  end

  def remove_request(state, piece_index, begin) do
    new_requests = Map.delete(state.active_requests, {piece_index, begin})
    %{state | active_requests: new_requests}
  end

  def has_piece?(state, piece_index) do
    MapSet.member?(state.available_pieces, piece_index)
  end

  def can_request?(state, max_requests) do
    state.am_interested and not state.peer_choking and
      map_size(state.active_requests) < max_requests
  end

  def request_count(state) do
    map_size(state.active_requests)
  end
end
