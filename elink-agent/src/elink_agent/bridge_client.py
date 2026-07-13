from __future__ import annotations

import json
from urllib.request import Request, urlopen

from .models import StatusSnapshot


class BridgeClient:
    def __init__(self, base_url: str, timeout: float = 3.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def fetch_status(self) -> StatusSnapshot:
        request = Request(
            f"{self.base_url}/v1/status",
            headers={"Accept": "application/json", "User-Agent": "elink-agent/0.1"},
        )
        with urlopen(request, timeout=self.timeout) as response:
            if response.status != 200:
                raise OSError(f"bridge returned HTTP {response.status}")
            return StatusSnapshot.from_dict(json.load(response))
