# hlsts
Convert HLS input to TS HTTP output stream

This tool is designed for converting HLS/HTTP stream to TS/HTTP.

Usage:
hlsts_server.pl 8888 http://example.hlsserver.com/stream.m3u8
It will listen for requests to port 8888 and translate given HLS stream to playlist.
Can be checked via vlc or mplayer. Any url part after "/" is accepted.

Known bugs:
Encrypted stream support commented and not tested.
Each client connection will open new connection to HLS server. So 30 clients will open 30 HLS workers.

Parts of code taken from:
https://github.com/osklil/hls-fetch (licensed under GPL)
https://renenyffenegger.ch/notes/development/languages/Perl/misc/webserver (unknown or public domain license)
