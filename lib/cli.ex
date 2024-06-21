defmodule Bittorrent.CLI do
  alias Bittorrent.Bencode
  alias Bittorrent.TorrentFile
  alias Bittorrent.Protocol

  @client_id :crypto.strong_rand_bytes(20)

  def main(["decode" | tail]) do
    case tail do
      [str] ->
        case Bencode.decode(str) do
          {:error, reason} ->
            IO.puts(reason)

          {decoded, remaining} ->
            IO.puts(Jason.encode!(decoded))

            if remaining != "" do
              IO.puts("Warning ! Remaining data has not been decoded: #{remaining}")
            end
        end

      _ ->
        IO.puts("Usage: your_bittorrent.sh decode <encoded_string>")
    end
  end

  def main(["info" | tail]) do
    case tail do
      [filename] ->
        file = TorrentFile.parse(filename)

        case file do
          {:error, reason} ->
            IO.puts(reason)

          file ->
            IO.puts("Tracker URL: #{file.tracker_url}")
            IO.puts("Length: #{file.length}")
            IO.puts("Info Hash: #{Base.encode16(file.info_hash, case: :lower)}")
            IO.puts("Piece Length: #{file.piece_length}")
            IO.puts("Piece Hashes:")

            Enum.each(file.piece_hashes, fn hash ->
              Base.encode16(hash, case: :lower)
              |> IO.puts()
            end)
        end

      _ ->
        IO.puts("Usage: your_bittorrent.sh info <path/to/torrent/file>")
    end
  end

  def main(["peers" | tail]) do
    case tail do
      [filename] ->
        file = TorrentFile.parse(filename)

        case file do
          {:error, reason} ->
            IO.puts(reason)

          file ->
            case Protocol.discover_peers(file, @client_id) do
              {:error, reason} ->
                IO.puts(reason)

              peers ->
                Enum.each(peers, fn address -> IO.puts(address) end)
            end
        end

      _ ->
        IO.puts("Usage: your_bittorrent.sh peers <path/to/torrent/file>")
    end
  end

  def main(["handshake" | tail]) do
    case tail do
      [filename, address | _] ->
        file = TorrentFile.parse(filename)

        case file do
          {:error, reason} ->
            IO.puts(reason)

          file ->
            case Bittorrent.Protocol.handshake(address, file.info_hash, @client_id) do
              {:error, reason} ->
                IO.puts(reason)

              {_, peer_id} ->
                IO.puts("Peer ID: #{peer_id}")
            end
        end

      _ ->
        IO.puts("Usage: your_bittorrent.sh handshake <path/to/torrent/file> <ip>:<port>")
    end
  end

  def main([command | _]) do
    IO.puts("Unknown command: #{command}")
    System.halt(1)
  end

  def main([]) do
    IO.puts("Usage: your_bittorrent.sh <command> <args>")
    System.halt(1)
  end
end
