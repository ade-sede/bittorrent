defmodule Bittorrent.PeerState do
  import Bitwise
  alias Bittorrent.Protocol
  require Bittorrent.Protocol

  defstruct [
    :peer_id,
    :available_pieces,
    :peer_choking,
    :am_interested,
    :extensions,
    :active_requests,
    :metadata_extension_id,
    :metadata_length,
    :number_expected_metadata_pieces,
    :number_received_metadata_pieces,
    :metadata_pieces
  ]

  def new(peer_id, extensions) do
    %__MODULE__{
      peer_id: peer_id,
      available_pieces: MapSet.new(),
      peer_choking: true,
      am_interested: false,
      extensions: extensions,
      active_requests: %{},
      metadata_extension_id: nil,
      metadata_length: 0,
      number_expected_metadata_pieces: 0,
      number_received_metadata_pieces: 0,
      metadata_pieces: <<>>
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

  def set_metadata_extension_id(state, id) do
    %{state | metadata_extension_id: id}
  end

  def set_metadata_length(state, length) do
    %{state | metadata_length: length}
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

  def extension_protocol_enabled?(state) do
    MapSet.member?(state.extensions, Protocol.extension_protocol())
  end

  def set_number_expected_metadata_pieces(state, n) do
    %{state | number_expected_metadata_pieces: n}
  end

  def append_metadata_piece(state, meta) do
    if state.number_received_metadata_pieces >= state.number_expected_metadata_pieces do
      IO.puts("Received too  many meta pieces")
      state
    else
      %{
        state
        | metadata_pieces: state.metadata_pieces <> meta,
          number_received_metadata_pieces: state.number_received_metadata_pieces + 1
      }
    end
  end
end
