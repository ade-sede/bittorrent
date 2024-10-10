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
  @download_timeout 300_000

  def main(args), do: parse_args(args)

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
        print_info(file)
    end
  end

  defp parse_args(["peers", filename]) do
    case TorrentInfo.parse_file(filename) do
      {:error, reason} ->
        IO.puts(reason)

      {:ok, file} ->
        case Protocol.discover_peers(file, @client_id) do
          {:error, reason} -> IO.puts(reason)
          {:ok, peers} -> Enum.each(peers, &IO.puts/1)
        end
    end
  end

  defp parse_args(["handshake", filename, peer_address]) do
    case TorrentInfo.parse_file(filename) do
      {:error, reason} ->
        IO.puts(reason)

      {:ok, file} ->
        case Protocol.handshake(peer_address, file.info_hash, @client_id, []) do
          {:error, reason} -> IO.puts(reason)
          {_socket, peer_id, _extensions} -> IO.puts("Peer ID: #{peer_id}")
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
    case TorrentInfo.from_magnet_link(magnet_link) do
      {:error, reason} -> IO.puts("Error: #{reason}")
      {:ok, file} -> print_info(file)
    end
  end

  defp parse_args(["magnet_handshake", magnet_link]) do
    with {:ok, file} <- TorrentInfo.from_magnet_link(magnet_link),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id),
         [peer | _] <- peers,
         {:ok, queue} <- DownloadQueue.start_link({file.info_hash, nil, nil, [], self(), :all}) do
      logger = create_logger(:blue)

      peer_spec = %{
        id: peer,
        start:
          {PeerConnection, :start_link,
           [{peer, file.info_hash, @client_id, self(), queue, @magnet_extensions, logger}]}
      }

      {:ok, supervisor_pid} = Supervisor.start_link([peer_spec], strategy: :one_for_one)

      receive do
        {_, :peer_id, peer_id} ->
          IO.puts("Peer ID: #{peer_id}")

          receive do
            {_, :peer_ut_metadata, {_, extension_id}} ->
              IO.puts("Peer Metadata Extension ID: #{extension_id}")
              Supervisor.stop(supervisor_pid)
          end
      after
        10_000 ->
          IO.puts("Timeout")
          Supervisor.stop(supervisor_pid)
      end
    end
  end

  defp parse_args(["magnet_info", magnet_link]) do
    with {:ok, file} <- TorrentInfo.from_magnet_link(magnet_link),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id),
         {:ok, queue} <- DownloadQueue.start_link({file.info_hash, nil, nil, [], self(), :all}) do
      peer_specs = create_peer_specs(peers, file.info_hash, queue, @magnet_extensions)
      {:ok, supervisor_pid} = Supervisor.start_link(peer_specs, strategy: :one_for_one)

      print_info(file)

      receive do
        {_, :peer_id, peer_id} ->
          IO.puts("Peer ID: #{peer_id}")

          receive do
            {pid, :peer_ut_metadata, {_, extension_id}} ->
              IO.puts("Peer Metadata Extension ID: #{extension_id}")
              GenServer.call(pid, :request_metadata)

              receive do
                {_, :received_all_metadata, meta} ->
                  {meta, _} = Bencode.decode(meta)
                  file = TorrentInfo.merge_metadata(file, meta)
                  print_info(file)
              end

              Supervisor.stop(supervisor_pid)
          end
      after
        @download_timeout ->
          IO.puts("Timeout")
          Supervisor.stop(supervisor_pid)
      end
    end
  end

  defp parse_args(["magnet_download_piece", "-o", output_file, magnet_link, piece_index]) do
    magnet_download_piece(magnet_link, String.to_integer(piece_index), output_file)
  end

  defp parse_args(["magnet_download", "-o", output_file, magnet_link]) do
    magnet_download(magnet_link, output_file)
  end

  defp parse_args(_) do
    IO.puts("Invalid command. Usage: your_bittorrent.sh <command> <args>")
  end

  defp download_piece(torrent_file, piece_index, output_file) do
    download(:regular, torrent_file, piece_index, output_file)
  end

  defp magnet_download_piece(magnet_link, piece_index, output_file) do
    download(:magnet, magnet_link, piece_index, output_file)
  end

  defp download_file(torrent_file, output_file) do
    download(:regular, torrent_file, :all, output_file)
  end

  defp magnet_download(magnet_link, output_file) do
    download(:magnet, magnet_link, :all, output_file)
  end

  defp download(type, source, piece_index, output_file) do
    file_parser =
      if type == :magnet, do: &TorrentInfo.from_magnet_link/1, else: &TorrentInfo.parse_file/1

    extensions = if type == :magnet, do: @magnet_extensions, else: []

    with {:ok, file} <- file_parser.(source),
         {:ok, peers} <- Protocol.discover_peers(file, @client_id) do
      piece_hashes = if type == :magnet, do: [], else: file.piece_hashes

      {:ok, queue} =
        DownloadQueue.start_link(
          {file.info_hash, file.piece_length, file.length, piece_hashes, self(), piece_index}
        )

      peer_specs = create_peer_specs(peers, file.info_hash, queue, extensions)
      {:ok, supervisor_pid} = Supervisor.start_link(peer_specs, strategy: :one_for_one)

      result =
        if type == :magnet do
          handle_magnet_download(supervisor_pid, piece_index, file, queue)
        else
          handle_regular_download(supervisor_pid, piece_index, file)
        end

      case result do
        {:ok, pieces} ->
          write_output(pieces, output_file, source, piece_index)
          Supervisor.stop(supervisor_pid)

        {:error, :timeout} ->
          IO.puts("Timeout")
          Supervisor.stop(supervisor_pid)
      end
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp handle_magnet_download(supervisor_pid, piece_index, file, queue) do
    receive do
      {pid, :peer_ut_metadata, _} ->
        GenServer.call(pid, :request_metadata)

        receive do
          {_, :received_all_metadata, meta} ->
            {meta, _} = Bencode.decode(meta)
            file = TorrentInfo.merge_metadata(file, meta)

            GenServer.call(
              queue,
              {:initialize_blocks, file.piece_hashes, file.piece_length, file.length}
            )

            supervisor_pid
            |> Supervisor.which_children()
            |> Enum.each(fn {_, peer, _, _} ->
              GenServer.cast(peer, :new_downloads_available)
            end)

            download_pieces(piece_index, file.piece_hashes)
        end
    after
      @download_timeout -> {:error, :timeout}
    end
  end

  defp handle_regular_download(_supervisor_pid, piece_index, file) do
    download_pieces(piece_index, file.piece_hashes)
  end

  defp download_pieces(:all, piece_hashes) do
    case gather_pieces(%{}, length(piece_hashes)) do
      pieces when map_size(pieces) > 0 -> {:ok, pieces}
      _ -> {:error, :timeout}
    end
  end

  defp download_pieces(piece_index, _piece_hashes) do
    receive do
      {:done, ^piece_index, piece_data} -> {:ok, %{piece_index => piece_data}}
    after
      @download_timeout -> {:error, :timeout}
    end
  end

  defp gather_pieces(pieces, total_pieces) when map_size(pieces) == total_pieces, do: pieces

  defp gather_pieces(pieces, total_pieces) do
    receive do
      {:done, piece_index, piece_data} ->
        gather_pieces(Map.put(pieces, piece_index, piece_data), total_pieces)

      :all_pieces_completed ->
        pieces
    after
      @download_timeout ->
        IO.puts("Download timed out")
        pieces
    end
  end

  defp write_output(pieces, output_file, source, :all = _piece_index) do
    write_file_from_pieces(pieces, output_file)

    if is_binary(source),
      do: IO.puts("Downloaded #{source} to #{output_file}"),
      else: IO.puts("Downloaded to #{output_file}")
  end

  defp write_output(pieces, output_file, _source, piece_index) do
    case Map.fetch(pieces, piece_index) do
      {:ok, data} ->
        File.write!(output_file, data)
        IO.puts("Piece #{piece_index} downloaded to #{output_file}")

      :error ->
        IO.puts("Failed to download piece #{piece_index}")
    end
  end

  defp write_file_from_pieces(pieces, output_file) do
    pieces
    |> Map.to_list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Enum.join()
    |> then(&File.write!(output_file, &1))
  end

  defp print_info(file) do
    IO.puts("Tracker URL: #{file.tracker_url}")
    if file.length, do: IO.puts("Length: #{file.length}")
    IO.puts("Info Hash: #{Base.encode16(file.info_hash, case: :lower)}")
    if file.piece_length, do: IO.puts("Piece Length: #{file.piece_length}")

    if file.piece_hashes do
      IO.puts("Piece Hashes:")
      Enum.each(file.piece_hashes, &IO.puts(Base.encode16(&1, case: :lower)))
    end
  end

  defp create_peer_specs(peers, info_hash, queue, extensions) do
    Enum.reduce(peers, {@colors, []}, fn peer, {colors, specs} ->
      {color, remaining_colors} = assign_color(colors)
      logger = create_logger(color)

      new_peer_spec = %{
        id: peer,
        start:
          {PeerConnection, :start_link,
           [{peer, info_hash, @client_id, self(), queue, extensions, logger}]}
      }

      {remaining_colors, specs ++ [new_peer_spec]}
    end)
    |> elem(1)
  end

  defp assign_color([]), do: {:black, []}
  defp assign_color([color | rest]), do: {color, rest}

  defp create_logger(color) do
    info_logger = fn message ->
      IO.puts(:stderr, IO.ANSI.format([color, "#{inspect(self())} - #{message}", :reset]))
    end

    error_logger = fn message ->
      IO.puts(:stderr, IO.ANSI.format([:red, "#{inspect(self())} - #{message}", :reset]))
    end

    {info_logger, error_logger}
  end
end
