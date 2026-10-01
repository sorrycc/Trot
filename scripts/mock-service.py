#!/usr/bin/env python3
"""A fake OpenAI-compatible service for trying the panel without a key.

    scripts/mock-service.py [port]          # default 48765

Then in Settings > Services pick OpenAI Compatible, set the base URL to
http://127.0.0.1:48765/v1 and any key. Paths change the behaviour:

    /v1/chat/completions       streams a translation one character at a time
    /slow/chat/completions     the same, slower, to watch the panel grow
    /fail/chat/completions     answers HTTP 500 with an error message
    /plain/chat/completions    ignores `stream` and answers with one JSON message
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TEXT = (
    "敏捷的棕色狐狸跳过了那只懒狗。翻译应用应该让人感觉即时响应，并且在做到这一点的同时看起来很美观。"
    "这一段文字比较长，用来检查面板在翻译流式到达时是否会平滑地增高，以及光标是否会闪烁。"
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        self.rfile.read(length)
        if "/fail/" in self.path:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "The model is overloaded, try again later."}}).encode())
            return
        if "/plain/" in self.path:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"choices": [{"message": {"content": TEXT}, "finish_reason": "stop"}]}).encode())
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        delay = 0.12 if "/slow/" in self.path else 0.03
        for character in TEXT:
            event = {"choices": [{"delta": {"content": character}}]}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
            time.sleep(delay)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 48765
    print("mock service on http://127.0.0.1:%d/v1" % port)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
