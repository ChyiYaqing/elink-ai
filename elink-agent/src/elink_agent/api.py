from __future__ import annotations

import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import __version__
from .service import AgentService

logger = logging.getLogger(__name__)


class AgentHTTPServer:
    def __init__(self, host: str, port: int, service: AgentService):
        handler = self._handler(service)
        self.server = ThreadingHTTPServer((host, port), handler)
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.thread = threading.Thread(target=self.server.serve_forever, name="elink-http", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        if self.thread:
            self.thread.join(timeout=5)

    @staticmethod
    def _handler(service: AgentService):
        class Handler(BaseHTTPRequestHandler):
            server_version = f"elink-agent/{__version__}"

            def do_GET(self) -> None:
                path = urlsplit(self.path).path
                if path in {"/", "/v1/device", "/v1/health"}:
                    self._json(200, service.device_info())
                elif path == "/v1/preview.png":
                    preview = service.preview_path()
                    try:
                        data = preview.read_bytes()
                    except OSError:
                        self._json(404, {"error": "no preview has been rendered"})
                    else:
                        self._send(200, "image/png", data)
                else:
                    self._json(404, {"error": "not found"})

            def do_POST(self) -> None:
                path = urlsplit(self.path).path
                try:
                    obj = self._body()
                    if path == "/v1/display/mode":
                        service.set_mode(str(obj.get("mode", "")))
                    elif path == "/v1/display/refresh":
                        service.request_refresh(str(obj.get("kind", "smart")))
                    else:
                        self._json(404, {"error": "not found"})
                        return
                except (ValueError, json.JSONDecodeError) as error:
                    self._json(400, {"error": str(error)})
                    return
                self._json(202, {"ok": True})

            def do_PUT(self) -> None:
                if urlsplit(self.path).path != "/v1/config/bridge":
                    self._json(404, {"error": "not found"})
                    return
                try:
                    obj = self._body()
                    bridge = obj.get("bridge_url")
                    if not isinstance(bridge, str) or not bridge.strip():
                        raise ValueError("bridge_url is required")
                    service.set_bridge(bridge.strip())
                except (ValueError, json.JSONDecodeError) as error:
                    self._json(400, {"error": str(error)})
                    return
                self._json(200, {"ok": True})

            def _body(self) -> dict:
                length = int(self.headers.get("Content-Length", "0"))
                if length > 65536:
                    raise ValueError("request body too large")
                if length == 0:
                    return {}
                obj = json.loads(self.rfile.read(length))
                if not isinstance(obj, dict):
                    raise ValueError("request body must be a JSON object")
                return obj

            def _json(self, status: int, obj: dict) -> None:
                self._send(status, "application/json", json.dumps(obj).encode())

            def _send(self, status: int, content_type: str, data: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, fmt: str, *args) -> None:
                logger.debug("HTTP %s - %s", self.address_string(), fmt % args)

        return Handler
