import http.server
import json
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9981

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        records = []
        for i in range(10):
            records.append({
                "id": i,
                "name": f"user_{i}",
                "email": f"user{i}@example.com",
                "score": i * 17 + 42,
            })
        body = json.dumps(records).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

print(f"python server on :{port}")
http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
