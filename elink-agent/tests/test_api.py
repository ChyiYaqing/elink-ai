import json
import socket
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen

from elink_agent.api import AgentHTTPServer
from elink_agent.config import AgentConfig
from elink_agent.display.mock import MockDisplay
from elink_agent.service import AgentService


def test_device_api_and_mode_change():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        service = AgentService(config, MockDisplay(config.output_path))
        server = AgentHTTPServer("127.0.0.1", 0, service)
        server.start()
        port = server.server.server_address[1]
        try:
            with urlopen(f"http://127.0.0.1:{port}/v1/device") as response:
                obj = json.load(response)
            assert obj["device_type"] == "elink-agent"
            request = Request(
                f"http://127.0.0.1:{port}/v1/display/mode",
                method="POST",
                data=b'{"mode":"claude"}',
                headers={"Content-Type": "application/json"},
            )
            with urlopen(request) as response:
                assert response.status == 202
            assert service.runtime.mode == "claude"

            raw = (b"POST /v1/display/refresh HTTP/1.1\r\n"
                   b"Host: localhost\r\nContent-Length: -1\r\n\r\n")
            with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
                conn.sendall(raw)
                status_line = conn.makefile("rb").readline()
            assert b"400" in status_line
        finally:
            server.stop()
