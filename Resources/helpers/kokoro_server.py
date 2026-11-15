"""23's local voice: a tiny Kokoro text-to-speech server.

Started on demand by 23, listens on 127.0.0.1 only, and exits by itself after a few idle minutes
so it uses no memory when 23 isn't talking.

POST /v1/audio/speech  {"input": "...", "voice": "af_heart", "speed": 1.0}
  -> raw mono 24 kHz signed 16-bit little-endian PCM
GET /health -> {"ok": true}
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
from kokoro_onnx import Kokoro

MODEL, VOICES, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
IDLE_SECONDS = int(sys.argv[4]) if len(sys.argv) > 4 else 300
MAX_CHARS = 1000

kokoro = Kokoro(MODEL, VOICES)
voice_names = set(kokoro.get_voices())
last_used = time.time()
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global last_used
        if self.path == "/health":
            last_used = time.time()
            self._json(200, {"ok": True, "voices": sorted(voice_names)})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        global last_used
        if self.path != "/v1/audio/speech":
            return self._json(404, {"error": "not found"})
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 64_000)
            req = json.loads(self.rfile.read(length) or b"{}")
            text = str(req.get("input", "")).strip()[:MAX_CHARS]
            voice = req.get("voice") if req.get("voice") in voice_names else "af_heart"
            speed = min(max(float(req.get("speed", 1.0)), 0.6), 1.6)
            if not text:
                return self._json(400, {"error": "empty input"})
            with lock:
                samples, _sr = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
                last_used = time.time()
            pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(pcm)))
            self.end_headers()
            self.wfile.write(pcm)
        except Exception as e:  # report, never crash the server
            self._json(500, {"error": str(e)[:300]})


def idle_watch(server):
    while True:
        time.sleep(15)
        if time.time() - last_used > IDLE_SECONDS:
            server.shutdown()
            return


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=idle_watch, args=(server,), daemon=True).start()
    server.serve_forever()
