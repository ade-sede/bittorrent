defmodule Bittorrent.Protocol do
  alias Bittorrent.Bencode

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
            for <<ip_port::binary-size(6) <- peers>> do
              <<a::8, b::8, c::8, d::8, port::16>> = ip_port
              "#{a}.#{b}.#{c}.#{d}:#{port}"
            end
        end
    end
  end

  def handshake(peer_address, info_hash, client_id) do
    [host, port] = String.split(peer_address, ":")
    {port, _} = Integer.parse(port)

    handshake_packet =
      <<19>> <>
        "BitTorrent protocol" <>
        <<0, 0, 0, 0, 0, 0, 0, 0>> <>
        info_hash <>
        client_id

    case :gen_tcp.connect(to_charlist(host), port, [:binary, active: false]) do
      {:error, reason} ->
        {:error, reason}

      {:ok, socket} ->
        case :gen_tcp.send(socket, handshake_packet) do
          {:error, reason} ->
            {:error, reason}

          _ ->
            case :gen_tcp.recv(socket, 68) do
              {:error, reason} ->
                {:error, reason}

              {:ok, packet} ->
                <<_ignored::size(48)-binary, id::size(20)-binary>> = packet
                {socket, Base.encode16(id, case: :lower)}
            end
        end
    end
  end

  def parse_message(message) do
    case message do
      <<0, 0, 0, 0>> ->
        :keep_alive

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
end
