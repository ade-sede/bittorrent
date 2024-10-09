["Build Your Own BitTorrent" Challenge](https://app.codecrafters.io/courses/bittorrent/overview).

In this challenge, you’ll build a BitTorrent client that's capable of parsing a
.torrent file and downloading a file from a peer. Along the way, we’ll learn
about how torrent files are structured, HTTP trackers, BitTorrent’s Peer
Protocol, pipelining and more.

# Usage

```bash
$> ./your_bittorrent.sh download -o /tmp/file.txt sample.torrent
```

Magnet links: WIP, waiting for tester to [be fixed](https://forum.codecrafters.io/t/cannot-finish-the-last-stage-handshake-fails-for-each-peer/1274/19)

# TODO

- Verify hash when an entire piece is assembled
- Resiliency when a peer crashes before all its scheduled blocks are downloaded
- Save UT_MEDATA and METADATA_LENGTH in the peer state
- All metadata blocks are 16k therefore METADATA_LENGTH / 16k gives you piece count
- Request metadata for each piece 1 by 1
- Make it so a peer can fill the download queue incrementally. Careful about race conditions when several peers are getting the same piece metadata
