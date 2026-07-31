from __future__ import annotations

import json
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .models import StatusSnapshot

# 状态文档是几个数字和几十个模型名，正常不到几十 KB。设一个上限是因为对面不一定
# 是自己人：桥接地址可以被局域网上的调用方改掉，而这个进程以 root 运行。
MAX_STATUS_BYTES = 1_048_576


class _NoRedirects(HTTPRedirectHandler):
    """桥接方不会重定向。

    跟随重定向等于把「目标必须是私有地址」这条检查作废：一个私有地址回一个 302，
    就能把请求带到任何地方去。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


class BridgeClient:
    def __init__(self, base_url: str, timeout: float = 3.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._opener = build_opener(_NoRedirects)

    def fetch_status(self) -> StatusSnapshot:
        request = Request(
            f"{self.base_url}/v1/status",
            headers={"Accept": "application/json", "User-Agent": "elink-agent/0.1"},
        )
        try:
            response = self._opener.open(request, timeout=self.timeout)
        except HTTPError as error:
            raise OSError(f"bridge returned HTTP {error.code}") from error
        with response:
            if response.status != 200:
                raise OSError(f"bridge returned HTTP {response.status}")
            # 多读一个字节：读满上限说明后面还有，直接判定超长而不是截断成半份 JSON
            body = response.read(MAX_STATUS_BYTES + 1)
            if len(body) > MAX_STATUS_BYTES:
                raise OSError("bridge status response is too large")
            return StatusSnapshot.from_dict(json.loads(body))
