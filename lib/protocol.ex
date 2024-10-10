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

  def handshake(peer_address, info_hash, client_id, extensions) do
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
        _decode_message(message_id, payload)

      # TCP frames are limited in size.
      # We may receive less than what is specified in length.
      <<length::32, _message_id::8, payload::binary>> when byte_size(payload) + 1 < length ->
        {:incomplete, length - byte_size(payload) - 1}

      # Or we may receive several messages in 1 frame
      <<length::32, message_id::8, payload::binary>> when byte_size(payload) + 1 > length ->
        expected_payload_size = length - 1

        <<current_payload::binary-size(expected_payload_size), rest::binary>> = payload
        message = _decode_message(message_id, current_payload)
        {:overflow, message, rest}
    end
  end

  defp _decode_message(id, payload) do
    case decode_message_id(id) do
      :extension ->
        <<extension_id::8, payload::binary>> = payload
        extension_id = decode_extension_message_id(extension_id)

        {:extension, {extension_id, payload}}

      id ->
        {id, payload}
    end
  end

  defp decode_message_id(0), do: :choke
  defp decode_message_id(1), do: :unchoke
  defp decode_message_id(2), do: :interested
  defp decode_message_id(3), do: :not_interested
  defp decode_message_id(4), do: :have
  defp decode_message_id(5), do: :bitfield
  defp decode_message_id(6), do: :request
  defp decode_message_id(7), do: :piece
  defp decode_message_id(8), do: :cancel
  defp decode_message_id(20), do: :extension
  defp decode_message_id(id), do: {:unknown, id}

  defp decode_extension_message_id(0), do: :handshake
  defp decode_extension_message_id(id), do: {:unknown, id}

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
        length = byte_size(encoded_dict) + 2

        {:ok, <<length::32, 20, 0, encoded_dict::binary>>}

      {:request_metadata, piece_index, extension_id} ->
        encoded_dict = Bencode.encode(%{"msg_type" => 0, "piece" => piece_index})
        length = byte_size(encoded_dict) + 2

        {:ok, <<length::32, 20, extension_id, encoded_dict::binary>>}

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
