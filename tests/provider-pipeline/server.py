import json, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PLAN = {"summary": "3.2 GB can go", "items": [
    {"title": "npm cache", "detail": "Caches", "group": "safe", "bytes": 1500000000,
     "paths": ["~/Library/Caches/npm"], "action": "trash", "command": ""},
    {"title": "brew cleanup", "detail": "Old versions", "group": "safe", "bytes": 300000000,
     "paths": [], "action": "command", "command": "brew cleanup"}]}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        if "401" in body:
            self.send_response(401)
            self.send_header("Content-Length", str(len('{"error":{"message":"bad key"}}')))
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}')
            return
        content = json.dumps(PLAN)
        if "fenced" in body:
            content = "Here is the plan:\n```json\n" + content + "\n```"
        if "plain" in body:
            out = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers(); self.wfile.write(out)
            return
        # SSE: two deltas so partial items stream first
        mid = len(content) // 2
        out = b""
        for part in (content[:mid], content[mid:]):
            out += b"data: " + json.dumps({"choices": [{"delta": {"content": part}}]}).encode() + b"\n\n"
        out += b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)

s = HTTPServer(("127.0.0.1", 18080), H)
threading.Thread(target=s.serve_forever, daemon=True).start()
import time
while True: time.sleep(1)
