defmodule Bittorrent.TorrentInfo do
  alias Bittorrent.Bencode

  defstruct tracker_url: nil,
            length: nil,
            info_hash: nil,
            base16_info_hash: nil,
            piece_length: nil,
            piece_hashes: nil,
            file_name: nil

  def parse_file(filename) do
    with {:ok, contents} <- File.read(filename),
         {metainfo, _} <- Bencode.decode(contents) do
      {:ok,
       %__MODULE__{
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

  def from_magnet_link(magnet_link) do
    uri = URI.parse(magnet_link)

    with "magnet" <- uri.scheme,
         query <- URI.query_decoder(uri.query) |> Enum.into(%{}),
         <<"urn:btih:", hash::binary-size(40)>> <- query["xt"],
         {:ok, decoded_hash} <- Base.decode16(hash, case: :mixed) do
      {:ok,
       %__MODULE__{
         tracker_url: query["tr"],
         file_name: query["dn"],
         info_hash: decoded_hash
       }}
    else
      _ -> {:error, "Malformed magnet URI"}
    end
  end
end
