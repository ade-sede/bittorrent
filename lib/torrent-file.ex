defmodule Bittorrent.TorrentFile do
  alias Bittorrent.Bencode

  defstruct tracker_url: nil,
            length: nil,
            info_hash: nil,
            piece_length: nil,
            piece_hashes: nil

  def parse(filename) do
    File.read!(filename)
    |> IO.iodata_to_binary()
    |> Bencode.decode()
    |> case do
      {:error, reason} ->
        {:error, reason}

      {metainfo, _} ->
        %Bittorrent.TorrentFile{
          tracker_url: metainfo["announce"],
          length: metainfo["info"]["length"],
          info_hash: :crypto.hash(:sha, Bencode.encode(metainfo["info"])),
          piece_length: metainfo["info"]["piece length"],
          piece_hashes:
            for <<piece_hash::size(20)-binary <- metainfo["info"]["pieces"]>> do
              piece_hash
            end
        }
    end
  end
end
