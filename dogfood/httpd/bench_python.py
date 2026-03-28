import http.server
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
directory = sys.argv[2] if len(sys.argv) > 2 else "www"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)
    def log_message(self, format, *args):
        pass

print(f"python serving {directory} on :{port}")
http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
