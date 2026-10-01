#!/usr/bin/env python3
"""A fake OpenAI-compatible service for trying the panel without a key.

    scripts/mock-service.py [port]          # default 48765

Then in Settings > Services pick OpenAI Compatible, set the base URL to
http://127.0.0.1:48765/v1 and any key. Paths change the behaviour:

    /v1/chat/completions       streams a translation one character at a time
    /slow/chat/completions     the same, slower, to watch the panel grow
    /fail/chat/completions     answers HTTP 500 with an error message
    /plain/chat/completions    ignores `stream` and answers with one JSON message
    /empty/chat/completions    a stream with no content at all
    /rtl/chat/completions      an Arabic paragraph, for right-to-left text
    /long/chat/completions     several screens of text, for the scrolling result
    /length/chat/completions   stops with finish_reason "length", as a cut-off reply does

The app can be pointed at it for one run, leaving the saved base URL and
key alone (the -service argument pins the service for that run):

    open build/Trot.app --args -service openAI \
        -service.openAI.baseURL http://127.0.0.1:48765/v1 -service.openAI.apiKey x -translate hello
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TEXT = (
    "敏捷的棕色狐狸跳过了那只懒狗。翻译应用应该让人感觉即时响应，并且在做到这一点的同时看起来很美观。"
    "这一段文字比较长，用来检查面板在翻译流式到达时是否会平滑地增高，以及光标是否会闪烁。"
)
RTL = "القفز السريع للثعلب البني فوق الكلب الكسول. يجب أن تبدو تطبيقات الترجمة فورية، وأن تبدو جميلة أثناء ذلك."
LONG = "\n\n".join(TEXT for _ in range(12))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def do_HEAD(self):
        # The app opens its connection ahead of the request with a HEAD.
        self.send_response(204)
        self.end_headers()

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
        text = TEXT
        if "/empty/" in self.path:
            text = ""
        elif "/rtl/" in self.path:
            text = RTL
        elif "/long/" in self.path:
            text = LONG
        delay = 0.12 if "/slow/" in self.path else 0.005 if "/long/" in self.path else 0.03
        for character in text:
            event = {"choices": [{"delta": {"content": character}}]}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
            time.sleep(delay)
        if "/length/" in self.path:
            event = {"choices": [{"delta": {}, "finish_reason": "length"}]}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 48765
    print("mock service on http://127.0.0.1:%d/v1" % port)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
