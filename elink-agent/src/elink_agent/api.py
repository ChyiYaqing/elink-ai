from __future__ import annotations

import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import __version__
from .service import AgentService

logger = logging.getLogger(__name__)


class _BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """并发连接数封顶。

    每个连接一个线程，而线程在读到完整请求前会一直等着。没有上限时，局域网上的
    调用方只要不断建连接、宣称一个 body 长度然后不发，就能把这个 root 进程的线程
    和内存吃干净。超出上限直接关连接：这条路上没有值得排队的请求。
    """

    daemon_threads = True
    max_workers = 16

    def __init__(self, *args, **kwargs):
        self._slots = threading.BoundedSemaphore(self.max_workers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            logger.warning("rejecting connection from %s: worker limit reached", client_address)
            # close_request 而不是 shutdown_request：后者会归还一个没拿到的名额，
            # BoundedSemaphore 对多还的一次会直接抛
            self.close_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def shutdown_request(self, request):
        try:
            super().shutdown_request(request)
        finally:
            self._slots.release()


class AgentHTTPServer:
    def __init__(self, host: str, port: int, service: AgentService):
        handler = self._handler(service)
        self.server = _BoundedThreadingHTTPServer((host, port), handler)
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
            # 宣称一个 body 长度然后不发（或者一秒一个字节），读会一直阻塞。给连接
            # 设死超时，慢速客户端最多占住一个 worker 十秒。
            timeout = 10

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
                if length < 0 or length > 65536:
                    raise ValueError("invalid request body length")
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
