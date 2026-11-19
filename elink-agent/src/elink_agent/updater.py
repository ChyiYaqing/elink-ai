"""设备端自更新：从 GitHub Release 拉取签名的 agent 包，安装、重启、验证，失败回滚。

由 elink-agent-update.timer 定期以 root 运行。agent 服务本身受 ProtectSystem=strict
限制写不了 /opt/elink-ai，所以更新放在这个独立的 oneshot 单元里做。
"""
from __future__ import annotations

import argparse
import base64
import http.client
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import tomllib
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import __version__
from .config import AgentConfig

log = logging.getLogger(__name__)

RELEASES_API = "https://api.github.com/repos/ChyiYaqing/elink-ai/releases?per_page=30"
ASSET_API_PREFIX = "https://api.github.com/repos/ChyiYaqing/elink-ai/releases/assets/"
# 与 mac-app/Info.plist 的 ElinkUpdatePublicKey 相同：已安装的设备只信任它出厂时带的公钥。
UPDATE_PUBLIC_KEY = "X13CG3OCZ3S1jXVpEuQ8K++7mfSFTVL/dD7aH0ARITg="
MAX_ARCHIVE_SIZE = 50 * 1024 * 1024
MAX_SIGNATURE_SIZE = 1024
HEALTH_TIMEOUT_S = 60.0


class UpdateError(Exception):
    pass


class RollbackFailed(UpdateError):
    """新版失败，且旧版也没能装回去。"""


# MARK: - 版本

_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$")


def parse_version(text: str) -> tuple[int, int, int, int | None] | None:
    match = _VERSION.match(text)
    if not match:
        return None
    major, minor, patch, rc = match.groups()
    return int(major), int(minor), int(patch), int(rc) if rc else None


def _sort_key(version: tuple[int, int, int, int | None]) -> tuple[int, int, int, int, int]:
    # 0.1.0-rc1 < 0.1.0-rc2 < 0.1.0
    major, minor, patch, rc = version
    return major, minor, patch, 0 if rc is not None else 1, rc or 0


@dataclass(frozen=True)
class AgentRelease:
    version: str
    archive_url: str
    signature_url: str

    @property
    def archive_name(self) -> str:
        return f"elink-agent-v{self.version}.tar.gz"


def newest_release(releases: list[dict], current: str) -> AgentRelease | None:
    """比 `current` 新的最高版本。正式版只升级到正式版；rc 也接受更新的 rc。"""
    current_version = parse_version(current)
    if current_version is None:
        raise UpdateError(f"cannot parse current version {current!r}")
    best: tuple[tuple, AgentRelease] | None = None
    for release in releases:
        tag = str(release.get("tag_name", ""))
        version = parse_version(tag[1:]) if tag.startswith("v") else None
        if release.get("draft") or version is None:
            continue
        # 正式版设备不接受 rc，也不接受在 GitHub 上标成预发布的版本。
        if (version[3] is not None or release.get("prerelease")) and current_version[3] is None:
            continue
        if _sort_key(version) <= _sort_key(current_version):
            continue
        name = f"elink-agent-{tag}.tar.gz"
        assets = {asset.get("name"): str(asset.get("url", "")) for asset in release.get("assets", [])}
        archive, signature = assets.get(name), assets.get(name + ".sig")
        if not archive or not signature or not all(
                url.startswith(ASSET_API_PREFIX) for url in (archive, signature)):
            continue
        if best is None or _sort_key(version) > best[0]:
            best = (_sort_key(version), AgentRelease(tag[1:], archive, signature))
    return best[1] if best else None


# MARK: - 下载、验签、解包

def http_get(url: str, *, accept: str, limit: int, token: str | None) -> bytes:
    request = urllib.request.Request(url, headers={
        "Accept": accept,
        "User-Agent": f"elink-agent/{__version__}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    if token:
        # 不随重定向转发：资源最终落在带签名的存储地址上，多带一个 Authorization 会被拒绝。
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise UpdateError(f"{url} exceeds {limit} bytes")
    return data


def verify_signature(data: bytes, signature: bytes, public_key: str) -> None:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True))
        raw = base64.b64decode(signature.strip(), validate=True)
        key.verify(raw, data)
    except (InvalidSignature, ValueError) as error:
        raise UpdateError("update signature verification failed") from error


def extract_source(archive: Path, destination: Path, expected_version: str) -> Path:
    """解出 `pyproject.toml` 与 `elink-agent/`，拒绝其他任何内容，并核对版本号。"""
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            parts = Path(member.name).parts
            if (member.name.startswith("/") or ".." in parts or not parts
                    or not (member.isfile() or member.isdir())
                    or (parts[0] != "elink-agent" and member.name != "pyproject.toml")):
                raise UpdateError(f"unexpected archive member {member.name!r}")
        destination.mkdir(parents=True)
        # 成员已逐一检查过；有 data 过滤器的 Python（3.11.4+）再加一道防线。
        extra = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        tar.extractall(destination, members=members, **extra)
    with open(destination / "pyproject.toml", "rb") as handle:
        project_version = tomllib.load(handle)["project"]["version"]
    init = (destination / "elink-agent/src/elink_agent/__init__.py").read_text()
    if project_version != expected_version or f'__version__ = "{expected_version}"' not in init:
        raise UpdateError("archive version does not match the release")
    return destination


# MARK: - 安装与回滚

Run = Callable[[list[str]], None]


def run_command(command: list[str]) -> None:
    subprocess.run(command, check=True, timeout=600)


def health_url(host: str, port: int) -> str:
    """agent 只绑定 `listen_host`；绑定通配地址时从本机回环访问。"""
    if host in ("", "0.0.0.0", "::"):
        host = "127.0.0.1"
    elif ":" in host:
        host = f"[{host}]"
    return f"http://{host}:{port}/v1/health"


def wait_for_version(url: str, expected: str, timeout_s: float = HEALTH_TIMEOUT_S) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if json.load(response).get("version") == expected:
                    return True
        except (OSError, ValueError, http.client.HTTPException):
            pass  # 新进程还没起来，或响应被截断：都算这一次探测失败
        time.sleep(2)
    return False


@dataclass
class Installer:
    """`baseline` 是指向当前已安装源码目录的符号链接，回滚就从它重新安装。

    它由 root 所有、其他用户不可写：回滚以 root 执行，不能装一份别人改过的源码。
    """
    baseline: Path
    python: str
    health_url: str
    run: Run = run_command
    healthy: Callable[[str, str], bool] = wait_for_version

    def _install(self, source: Path) -> None:
        self.run([self.python, "-m", "pip", "install", "--no-deps", "--no-build-isolation", str(source)])
        self.run(["systemctl", "restart", "elink-agent"])

    def install(self, source: Path, version: str, previous: str) -> None:
        """装新版并确认它跑起来；任何一步失败都从基线装回 `previous` 并确认它跑起来。"""
        try:
            self._install(source)
            if not self.healthy(self.health_url, version):
                raise UpdateError(f"elink-agent did not report version {version} after restart")
            # 基线切换也在事务里：切不过去就回到旧版，保证运行的版本和基线一致。
            self._promote(source, version)
        except Exception as error:
            log.error("update to %s failed, rolling back: %s", version, error)
            try:
                self._install(self.baseline.resolve())
                restored = self.healthy(self.health_url, previous)
            except Exception as rollback_error:
                raise RollbackFailed(f"rollback to {previous} failed: {rollback_error}") from error
            if not restored:
                raise RollbackFailed(f"rollback to {previous} did not come back up") from error
            raise

    def _promote(self, source: Path, version: str) -> None:
        """新源码完整拷进 `source-<version>` 后，再原子地把基线链接切过去。"""
        root = self.baseline.parent
        target = root / f"source-{version}"
        staging = root / f".source-{version}.tmp"
        link = root / ".source.link"
        for leftover in (staging, link):
            if leftover.is_symlink() or leftover.is_file():
                leftover.unlink()
            elif leftover.exists():
                shutil.rmtree(leftover)
        shutil.copytree(source, staging)
        if target.exists():
            shutil.rmtree(target)
        os.rename(staging, target)
        os.symlink(target.name, link)
        os.replace(link, self.baseline)
        for old in root.glob("source-*"):
            if old != target and old.is_dir() and not old.is_symlink():
                shutil.rmtree(old, ignore_errors=True)


# MARK: - 入口

def update(*, work_dir: Path, installer: Installer, failed_record: Path,
           current: str = __version__, token: str | None = None,
           get: Callable[..., bytes] = http_get,
           running: Callable[[], bool] = lambda: agent_running()) -> str | None:
    # 只更新正在运行的 agent：管理员停掉的服务不能被安装或回滚重新拉起来。
    if not running():
        log.info("elink-agent is not running; skipping update")
        return None
    releases = json.loads(get(RELEASES_API, accept="application/vnd.github+json",
                              limit=2 * 1024 * 1024, token=token))
    release = newest_release(releases, current)
    if release is None:
        log.info("elink-agent %s is up to date", current)
        return None
    # 装过且回滚了的版本不再自动重试，否则每次定时检查都会重启、回滚一遍。
    if failed_record.exists() and failed_record.read_text().strip() == release.version:
        log.warning("skipping %s: it failed and was rolled back; delete %s to retry",
                    release.version, failed_record)
        return None
    log.info("updating elink-agent %s -> %s", current, release.version)
    signature = get(release.signature_url, accept="application/octet-stream",
                    limit=MAX_SIGNATURE_SIZE, token=token)
    data = get(release.archive_url, accept="application/octet-stream",
               limit=MAX_ARCHIVE_SIZE, token=token)
    verify_signature(data, signature, UPDATE_PUBLIC_KEY)
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)
    try:
        archive = work_dir / release.archive_name
        archive.write_bytes(data)
        source = extract_source(archive, work_dir / "source", release.version)
        if not running():  # 下载期间被停掉了
            log.info("elink-agent was stopped during the update; skipping")
            return None
        try:
            installer.install(source, release.version, current)
        except RollbackFailed:
            raise  # 旧版没有确认恢复：不记成「已回滚」，需要人工处理（见 README）
        except Exception:
            failed_record.write_text(release.version + "\n")
            raise
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
    log.info("elink-agent updated to %s", release.version)
    return release.version


def agent_running() -> bool:
    return subprocess.run(["systemctl", "is-active", "--quiet", "elink-agent"]).returncode == 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Update elink-agent from GitHub Releases")
    parser.add_argument("--config", default="/etc/elink-ai/config.toml")
    parser.add_argument("--baseline", default="/opt/elink-ai/source")
    parser.add_argument("--work-dir", default="/var/lib/elink-ai/update")
    parser.add_argument("--failed-record", default="/var/lib/elink-ai/update-failed")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    config = AgentConfig.load(args.config)
    installer = Installer(Path(args.baseline), sys.executable,
                          health_url(config.listen_host, config.listen_port))
    try:
        update(work_dir=Path(args.work_dir), installer=installer, failed_record=Path(args.failed_record),
               token=os.environ.get("GITHUB_TOKEN") or None)
    except Exception as error:  # noqa: BLE001 - systemd 记录失败原因并以非零退出
        log.error("update failed: %s: %s", type(error).__name__, error)
        sys.exit(1)


if __name__ == "__main__":
    main()
