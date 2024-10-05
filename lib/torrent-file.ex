defmodule Bittorrent.TorrentFile do
  alias Bittorrent.Bencode

  defstruct tracker_url: nil,
            length: nil,
            info_hash: nil,
            piece_length: nil,
            piece_hashes: nil

  def parse(filename) do
    with {:ok, contents} <- File.read(filename),
         {metainfo, _} <- Bencode.decode(contents) do
      {:ok,
       %Bittorrent.TorrentFile{
         tracker_url: metainfo["announce"],
         length: metainfo["info"]["length"],
         info_hash: :crypto.hash(:sha, Bencode.encode(metainfo["info"])),
         piece_length: metainfo["info"]["piece length"],
         piece_hashes:
           for <<piece_hash::binary-size(20) <- metainfo["info"]["pieces"]>> do
             piece_hash
           end
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Failed to parse torrent file"}
    end
  end
end
