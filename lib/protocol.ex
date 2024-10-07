defmodule Bittorrent.Protocol do
  import Bitwise
  alias Bittorrent.Bencode

  @extension_protocol 0x0000000000100000
  @all_extensions [@extension_protocol]

  defmacro extension_protocol, do: @extension_protocol

  def discover_peers(file, client_id) do
    Req.get!(file.tracker_url,
      params: %{
        "info_hash" => file.info_hash,
        "port" => 6881,
        "peer_id" => client_id,
        "uploaded" => 0,
        "downloaded" => 0,
        "left" => file.length,
        "compact" => 1
      }
    ).body
    |> Bencode.decode()
    |> case do
      {:error, reason} ->
        {:error, reason}

      {decoded, _} ->
        case Map.get(decoded, "peers") do
          nil ->
            {:error, "No key `peers` in received data"}

          peers ->
            peer_list = parse_peers(peers)
            {:ok, peer_list}
        end
    end
  end

  defp parse_peers(peers) do
    for <<ip_port::binary-size(6) <- peers>> do
      <<a::8, b::8, c::8, d::8, port::16>> = ip_port
      "#{a}.#{b}.#{c}.#{d}:#{port}"
    end
  end

  def handshake(peer_address, info_hash, client_id, extensions \\ []) do
    with [host, port] <- String.split(peer_address, ":"),
         {port, _} <- Integer.parse(port),
         handshake_packet <-
           pack_handshake_packet(info_hash, client_id, extensions),
         {:ok, socket} <- :gen_tcp.connect(to_charlist(host), port, [:binary, active: false]),
         :ok <- :gen_tcp.send(socket, handshake_packet),
         {:ok, packet} <- :gen_tcp.recv(socket, 68),
         {:ok, extensions, _, peer_id} <- unpack_handshake_packet(packet) do
      {socket, Base.encode16(peer_id, case: :lower), extensions}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Something went wrong somewhere. Possibly the split ?"}
    end
  end

  def decode_message(message) do
    case message do
      <<0, 0, 0, 0>> ->
        :keep_alive

      <<13::32, 16, index::32, begin::32, length::32>> ->
        {:reject_request, index, begin, length}

      <<length::32, message_id::8, payload::binary>> when byte_size(payload) + 1 == length ->
        case message_id do
          0 -> {:choke, payload}
          1 -> {:unchoke, payload}
          2 -> {:interested, payload}
          3 -> {:not_interested, payload}
          4 -> {:have, payload}
          5 -> {:bitfield, payload}
          6 -> {:request, payload}
          7 -> {:piece, payload}
          8 -> {:cancel, payload}
          _ -> {:unknown, payload}
        end

      <<length::32, _message_id::8, payload::binary>> ->
        {:incomplete, length - byte_size(payload) - 1}
    end
  end

  def encode_message(message) do
    case message do
      :keep_alive ->
        {:ok, <<0::32>>}

      :choke ->
        {:ok, <<1::32, 0>>}

      :unchoke ->
        {:ok, <<1::32, 1>>}

      :interested ->
        {:ok, <<1::32, 2>>}

      :not_interested ->
        {:ok, <<1::32, 3>>}

      {:have, piece_index} ->
        {:ok, <<5::32, 4, piece_index::32>>}

      {:bitfield, bitfield} ->
        {:ok, <<byte_size(bitfield) + 1::32, 5, bitfield::binary>>}

      {:request, index, begin, length} ->
        {:ok, <<13::32, 6, index::32, begin::32, length::32>>}

      {:piece, index, begin, block} ->
        block_length = byte_size(block)
        {:ok, <<block_length + 9::32, 7, index::32, begin::32, block::binary>>}

      {:cancel, index, begin, length} ->
        {:ok, <<13::32, 8, index::32, begin::32, length::32>>}

      {:extension, dictionary} ->
        encoded_dict = Bencode.encode(dictionary)
        length = 4 + byte_size(encoded_dict) + 2

        <<length::32, 20, 0, encoded_dict>>

      _ ->
        {:error, :unknown_message_type}
    end
  end

  defp pack_reserved_bytes(extensions) do
    packed_int =
      Enum.reduce(extensions, 0, fn extension, acc ->
        acc ||| extension
      end)

    <<packed_int::big-unsigned-integer-size(64)>>
  end

  defp unpack_reserved_bytes(reserved_bytes) do
    <<packed_int::big-unsigned-integer-size(64)>> = reserved_bytes

    Enum.reduce(@all_extensions, MapSet.new(), fn extension, acc ->
      if (packed_int &&& extension) != 0 do
        MapSet.put(acc, extension)
      else
        acc
      end
    end)
  end

  defp pack_handshake_packet(info_hash, client_id, extensions) do
    <<19>> <>
      "BitTorrent protocol" <>
      pack_reserved_bytes(extensions) <>
      info_hash <>
      client_id
  end

  defp unpack_handshake_packet(packet) do
    case packet do
      <<19, "BitTorrent protocol", reserved_bytes::size(8)-binary, info_hash::size(20)-binary,
        peer_id::size(20)-binary>> ->
        extensions = unpack_reserved_bytes(reserved_bytes)

        {:ok, extensions, info_hash, peer_id}

      _ ->
        {:error, "Handshake does not match any known format"}
    end
  end
end
