"""Serve a PipeWire null sink as an endless MP3 stream, internet-radio style.

One ffmpeg per client, spawned on GET and killed when the client goes away, so
nothing encodes while nobody is listening. The Cast receiver is the only client
in practice.
"""

import http.server
import socketserver
import subprocess
import sys

PORT, SINK = int(sys.argv[1]), sys.argv[2]


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
        self._headers()
        encoder = subprocess.Popen(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", "pulse", "-i", SINK,
                "-c:a", "libmp3lame", "-b:a", "192k", "-ar", "44100", "-ac", "2",
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
