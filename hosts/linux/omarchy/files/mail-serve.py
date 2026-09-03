"""Serve one directory on an ephemeral loopback port, printing the port first.

Port 0 so several filters (a digest with several html parts) cannot collide,
and the port goes to stdout because a shell cannot both background this and
read its output through a command substitution.
"""
import http.server, socketserver, sys, os
os.chdir(sys.argv[1])

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

srv = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
print(srv.server_address[1], flush=True)
srv.serve_forever()
