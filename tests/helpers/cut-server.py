#!/usr/bin/env python3
"""Local server for the bats tests: the first GET gets half of a body of 10 bytes and 4 s of silence,
the second the whole body. Usage: cut-server.py <port> <ready file>; it exits after two requests."""
import http.server
import sys
import threading
import time

BODY = b"B" * 10
count = 0
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global count
        with lock:
            count += 1
            first = count == 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        try:
            if first:
                self.wfile.write(b"A" * 5)
                self.wfile.flush()
                time.sleep(4)
            else:
                self.wfile.write(BODY)
        except OSError:
            pass

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.daemon_threads = False
server.timeout = 20
open(sys.argv[2], "w").close()
server.handle_request()
server.handle_request()
server.server_close()
