defmodule Bittorrent.CLI do
  require Bittorrent.Protocol
  alias Bittorrent.Bencode
  alias Bittorrent.TorrentInfo
  alias Bittorrent.Protocol
  alias Bittorrent.PeerConnection
  alias Bittorrent.DownloadQueue

  @client_id :crypto.strong_rand_bytes(20)
  @colors [
    :green,
    :yellow,
    :blue,
    :magenta,
    :cyan,
    :white,
    :black,
    :light_red,
    :light_green,
    :light_yellow,
    :light_blue,
    :light_magenta,
    :light_cyan
  ]

  @magnet_extensions [Protocol.extension_protocol()]

  def main(args) do
    parse_args(args)
  end

  defp parse_args(["decode" | [str]]) do
    case Bencode.decode(str) do
      {:error, reason} ->
        IO.puts(reason)

      {decoded, remaining} ->
        IO.puts(Jason.encode!(decoded))

        if remaining != "",
          do: IO.puts("Warning! Remaining data has not been decoded: #{remaining}")
    end
  end

  defp parse_args(["info", filename]) do
    case TorrentInfo.parse_file(filename) do
      {:error, reason} ->
        IO.puts(reason)

      {:ok, file} ->
        IO.puts("Tracker URL: #{file.tracker_url}")
        IO.puts("Length: #{file.length}")
        IO.puts("Info Hash: #{Base.encode16(file.info_hash, case: :lower)}")
        IO.puts("Piece Length: #{file.piece_length}")
        IO.puts("Piece Hashes:")
        Enum.each(file.piece_hashes, &IO.puts(Base.encode16(&1, case: :lower)))
    end
  end

  defp parse_args(["peers", filename]) do
    case TorrentInfo.parse_file(filename) do
      {:error, reason} ->
        IO.puts(reason)

      {:ok, file} ->
        case Protocol.discover_peers(file, @client_id) do
          {:error, reason} ->
            IO.puts(reason)

          {:ok, peers} ->
            Enum.each(peers, &IO.puts/1)
        end
    end
  end

  defp parse_args(["handshake", filename, peer_address]) do
    case TorrentInfo.parse_file(filename) do
      {:error, reason} ->
        IO.puts(reason)

      {:ok, file} ->
        case Protocol.handshake(peer_address, file.info_hash, @client_id, []) do
          {:error, reason} ->
            IO.puts(reason)

          {_socket, peer_id, _extensions} ->
            IO.puts("Peer ID: #{peer_id}")
        end
    end
  end

  defp parse_args(["download_piece", "-o", output_file, torrent_file, piece_index]) do
    download_piece(torrent_file, String.to_integer(piece_index), output_file)
  end

  defp parse_args(["download", "-o", output_file, torrent_file]) do
    download_file(torrent_file, output_file)
  end

  defp parse_args(["magnet_parse", magnet_link]) do
    with {:ok, file} <- TorrentInfo.from_magnet_link(magnet_link) do
      IO.puts("Tracker URL: #{file.tracker_url}")
      IO.puts("Info Hash: #{Base.encode16(file.info_hash, case: :lower)}")
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp parse_args(["magnet_handshake", magnet_link]) do
    with {:ok, file} <- TorrentInfo.from_magnet_link(magnet_link),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id),
         [peer | _] <- peers,
         {:ok, queue} <-
           DownloadQueue.start_link({file.info_hash, nil, nil, [], self(), :all}) do
      peer_spec = %{
        id: peer,
        start:
          {PeerConnection, :start_link,
           [{peer, file.info_hash, @client_id, self(), queue, @magnet_extensions, :blue}]}
      }

      {:ok, supervisor_pid} = Supervisor.start_link([peer_spec], strategy: :one_for_one)

      receive do
        {:peer_id, peer_id} ->
          IO.puts("Peer ID: #{peer_id}")

          receive do
            :extension_handshake_sent ->
              Supervisor.stop(supervisor_pid)
          end
      after
        10_000 ->
          IO.puts("Timeout")
          Supervisor.stop(supervisor_pid)
      end
    end
  end

  defp parse_args(_) do
    IO.puts("Invalid command. Usage: your_bittorrent.sh <command> <args>")
  end

  defp download_piece(torrent_file, piece_index, output_file) do
    with {:ok, file} <- TorrentInfo.parse_file(torrent_file),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id),
         {:ok, queue} <-
           DownloadQueue.start_link(
             {file.info_hash, file.piece_length, file.length, file.piece_hashes, self(),
              piece_index}
           ) do
      peer_specs =
        Enum.reduce(peers, {@colors, []}, fn peer, {colors, specs} ->
          {color, remaining_colors} = assign_color(colors)

          new_peer_spec = %{
            id: peer,
            start:
              {PeerConnection, :start_link,
               [{peer, file.info_hash, @client_id, self(), queue, [], color}]}
          }

          {remaining_colors, specs ++ [new_peer_spec]}
        end)
        |> elem(1)

      {:ok, supervisor_pid} = Supervisor.start_link(peer_specs, strategy: :one_for_one)

      receive do
        {:done, ^piece_index, piece_data} ->
          File.write!(output_file, piece_data)
          Supervisor.stop(supervisor_pid)
          IO.puts("Piece #{piece_index} downloaded to #{output_file}")
      after
        300_000 ->
          Supervisor.stop(supervisor_pid)
          IO.puts("Download timed out")
      end
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp download_file(torrent_file, output_file) do
    with {:ok, file} <- TorrentInfo.parse_file(torrent_file),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id),
         {:ok, queue} <-
           DownloadQueue.start_link(
             {file.info_hash, file.piece_length, file.length, file.piece_hashes, self(), :all}
           ) do
      peer_specs =
        Enum.reduce(peers, {@colors, []}, fn peer, {colors, specs} ->
          {color, remaining_colors} = assign_color(colors)

          new_peer_spec = %{
            id: peer,
            start:
              {PeerConnection, :start_link,
               [{peer, file.info_hash, @client_id, self(), queue, [], color}]}
          }

          {remaining_colors, specs ++ [new_peer_spec]}
        end)
        |> elem(1)

      {:ok, supervisor_pid} = Supervisor.start_link(peer_specs, strategy: :one_for_one)

      pieces = gather_pieces(%{}, length(file.piece_hashes))

      ordered_data =
        pieces
        |> Map.to_list()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
        |> Enum.join()

      File.write!(output_file, ordered_data)
      Supervisor.stop(supervisor_pid)
      IO.puts("Downloaded #{torrent_file} to #{output_file}")
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp gather_pieces(pieces, total_pieces) when map_size(pieces) == total_pieces do
    pieces
  end

  defp gather_pieces(pieces, total_pieces) do
    receive do
      {:done, piece_index, piece_data} ->
        gather_pieces(Map.put(pieces, piece_index, piece_data), total_pieces)

      :all_pieces_completed ->
        pieces
    after
      300_000 ->
        IO.puts("Download timed out")
        pieces
    end
  end

  defp assign_color([]), do: {:black, []}
  defp assign_color([color | rest]), do: {color, rest}
end
