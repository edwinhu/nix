"""Serve a PipeWire null sink as an endless MP3 stream, internet-radio style.

One ffmpeg per client, spawned on GET and killed when the client goes away, so
nothing encodes while nobody is listening. The Cast receiver is the only client
in practice.

Every change in the number of live GET handlers is printed as
`clients=N peer=<ip>`. That line is the wrapper's watchdog signal: a receiver
that stops pulling shows up here immediately, with no `catt status` round-trip
to hang on. The peer is the address of the client whose arrival or departure
caused the transition — the port is unauthenticated, so the wrapper needs it to
tell the speaker apart from any other LAN host that happens to GET the stream.
"""

import http.server
import os
import socketserver
import subprocess
import sys
import threading

PORT, SINK = int(sys.argv[1]), sys.argv[2]
# Measured on this speaker: 192k gave 7m48s and 4m21s between receiver drops,
# 96k gave 15m05s on the same AP. Less airtime, roughly double the uptime, and
# no audible difference here. Overridable for a link that can afford more.
BITRATE = os.environ.get("KEF_CAST_BITRATE", "96k")

_clients = 0
_clients_lock = threading.Lock()


def _clients_delta(delta, peer):
    """Adjust the live-handler count and announce the new value and the peer."""
    global _clients
    with _clients_lock:
        _clients += delta
        # Unbuffered and one line per transition: the wrapper reads this
        # incrementally, so a silent buffer would stall the watchdog.
        print(f"clients={_clients} peer={peer}", flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.0 leaves the receiver guessing about a body with no Content-Length.
    protocol_version = "HTTP/1.1"

    def _headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Cache-Control", "no-cache")
        # No Content-Length: the stream never ends. Closing on disconnect is how
        # the receiver learns the stream is over.
        self.send_header("Connection", "close")
        self.end_headers()

    def do_HEAD(self):
        self._headers()

    def do_GET(self):
        # Counted around the WHOLE handler, not just the copy loop: an attach
        # that dies before the encoder starts is still an attach that ended.
        # HEAD is deliberately not counted — it is a probe, not a receiver.
        # Reported on both edges so the wrapper can attribute the attach AND the
        # detach to a host. Taken from the accepted socket, not from a header:
        # a client cannot forge it.
        peer = self.client_address[0]
        _clients_delta(1, peer)
        try:
            self._stream()
        finally:
            _clients_delta(-1, peer)

    def _stream(self):
        self._headers()
        encoder = subprocess.Popen(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", "pulse", "-i", SINK,
                "-c:a", "libmp3lame", "-b:a", BITRATE, "-ar", "44100", "-ac", "2",
                # Xing/ID3 headers describe a file of known length; this is not one.
                "-f", "mp3", "-write_xing", "0", "-id3v2_version", "0", "-",
            ],
            stdout=subprocess.PIPE,
        )
        try:
            while True:
                chunk = encoder.stdout.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            encoder.kill()

    def log_message(self, *args):
        pass


socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as httpd:
    # The wrapper waits for this before casting. Probing the port from outside
    # cannot substitute: on a port collision the probe reaches whoever already
    # owns it and reports success while this process is busy dying.
    print("ready", flush=True)
    httpd.serve_forever()
