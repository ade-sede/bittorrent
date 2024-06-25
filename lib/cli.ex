defmodule Bittorrent.CLI do
  alias Bittorrent.DownloadQueue
  alias Bittorrent.Bencode
  alias Bittorrent.TorrentFile
  alias Bittorrent.Protocol
  alias Bittorrent.PeerConnection

  @client_id :crypto.strong_rand_bytes(20)
  @max_block_length 16384

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

  def main(["download_piece" | tail]) do
    case tail do
      ["-o", output_filename, torrent_filename, piece_index] ->
        file = TorrentFile.parse(torrent_filename)

        case file do
          {:error, reason} ->
            IO.puts(reason)

          file ->
            case Bittorrent.Protocol.discover_peers(file, @client_id) do
              {:error, reason} ->
                IO.puts(reason)

              peers ->
                queue_name = String.to_atom(Base.encode16(file.info_hash, case: :lower))

                blocks =
                  DownloadQueue.cut_file_into_blocks(
                    file.length,
                    length(file.piece_hashes),
                    file.piece_length,
                    @max_block_length
                  )
                  |> Enum.filter(fn {p_idx, _, _, _} ->
                    p_idx == String.to_integer(piece_index)
                  end)

                peer_connections =
                  Enum.map(peers, fn address ->
                    %{
                      id: address,
                      start:
                        {PeerConnection, :start_link,
                         [{address, file.info_hash, @client_id, queue_name}]},
                      restart: :temporary
                    }
                  end)

                download_queue = %{
                  id: queue_name,
                  start:
                    {DownloadQueue, :start_link,
                     [%DownloadQueue{name: queue_name, to_download: blocks, parent: self()}]}
                }

                {:ok, pid} =
                  Supervisor.start_link(
                    [download_queue | peer_connections],
                    strategy: :one_for_one,
                    name: Bittorrent.Supervisor
                  )

                receive do
                  {:done, blocks} ->
                    Supervisor.stop(pid, :normal)

                    bytes =
                      Enum.sort(blocks, fn {p1, b1, _, _, _}, {p2, b2, _, _, _} ->
                        cond do
                          p1 < p2 -> true
                          p1 > p2 -> false
                          true -> b1 < b2
                        end
                      end)
                      |> Enum.reduce("", fn {_, _, _, _, data}, acc -> acc <> data end)

                    case File.write(output_filename, bytes) do
                      {:error, reason} ->
                        IO.puts(reason)
                        System.halt(reason)

                      :ok ->
                        :ok
                    end
                end
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
