["Build Your Own BitTorrent" Challenge](https://app.codecrafters.io/courses/bittorrent/overview).

In this challenge, you’ll build a BitTorrent client that's capable of parsing a
.torrent file and downloading a file from a peer. Along the way, we’ll learn
about how torrent files are structured, HTTP trackers, BitTorrent’s Peer
Protocol, pipelining and more.


# Usage

```bash
$> ./your_bittorrent.sh download -o /tmp/file.txt sample.torrent
```

# TODO

- General resiliency
- Persist blocks to download / blocks downloaded
- Test with torrents other than the challenge's example
