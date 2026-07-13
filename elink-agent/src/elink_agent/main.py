from __future__ import annotations

import argparse
import logging
import signal
import threading

from .api import AgentHTTPServer
from .config import AgentConfig
from .display.mock import MockDisplay
from .service import AgentService


def build_display(config: AgentConfig):
    if config.display_driver == "mock":
        return MockDisplay(config.output_path)
    if config.display_driver == "waveshare_5in83_v2":
        from .display.waveshare_5in83_v2 import Waveshare583V2Display
        return Waveshare583V2Display()
    raise ValueError(f"unsupported display driver: {config.display_driver}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Claude/Codex e-paper dashboard agent")
    parser.add_argument("--config", default="/etc/elink-ai/config.toml")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    config = AgentConfig.load(args.config)
    service = AgentService(config, build_display(config))
    server = AgentHTTPServer(config.listen_host, config.listen_port, service)
    stopped = threading.Event()

    def stop(*_args) -> None:
        stopped.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    service.start()
    server.start()
    logging.getLogger(__name__).info("device API listening on %s:%s", config.listen_host, config.listen_port)
    try:
        stopped.wait()
    finally:
        server.stop()
        service.stop()


if __name__ == "__main__":
    main()
