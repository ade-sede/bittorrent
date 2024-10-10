["Build Your Own BitTorrent" Challenge](https://app.codecrafters.io/courses/bittorrent/overview).

In this challenge, you’ll build a BitTorrent client that's capable of parsing a
.torrent file and downloading a file from a peer. Along the way, we’ll learn
about how torrent files are structured, HTTP trackers, BitTorrent’s Peer
Protocol, pipelining and more.

# Dependencies

- [Erlang w/ OTP](https://www.erlang.org)
- [Elixir](https://elixir-lang.org/install.html)

# Usage

```bash
$> ./your_bittorrent.sh download -o /tmp/file.txt sample.torrent
# or using a magnet link
$> ./your_bittorrent.sh magnet_download -o "/tmp/file.gif" "magnet:?xt=urn:btih:c5fb9894bdaba464811b088d806bdd611ba490af&dn=magnet3.gif&tr=http%3A%2F%2Fbittorrent-test-tracker.codecrafters.io%2Fannounce"
```

# TODO

- Refactor command dispatch
- Test with real life torrents
