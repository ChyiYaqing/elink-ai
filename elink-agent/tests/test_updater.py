from __future__ import annotations

import base64
import http.client
import io
import json
import plistlib
import re
import subprocess
import tarfile
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from elink_agent import __version__, updater
from elink_agent.updater import Installer, UpdateError

ROOT = Path(__file__).resolve().parents[2]
API = updater.ASSET_API_PREFIX


def release(tag: str, *, draft: bool = False, assets: bool = True, prefix: str = API) -> dict:
    name = f"elink-agent-{tag}.tar.gz"
    return {
        "tag_name": tag, "draft": draft,
        "assets": [{"name": name, "url": prefix + "1"}, {"name": name + ".sig", "url": prefix + "2"}] if assets else [],
    }


def test_versions_order_candidates_before_finals() -> None:
    keys = [updater._sort_key(updater.parse_version(v)) for v in ("0.1.21-rc2", "0.1.21-rc10", "0.1.21", "0.1.22-rc1")]
    assert keys == sorted(keys)
    assert updater.parse_version("v0.1.21") is None


def test_final_release_only_moves_to_final_releases() -> None:
    releases = [release("v0.1.22-rc1"), release("v0.1.21")]
    assert updater.newest_release(releases, "0.1.20").version == "0.1.21"
    assert updater.newest_release([release("v0.1.22-rc1")], "0.1.21") is None


def test_candidate_moves_to_newer_candidates_and_finals() -> None:
    assert updater.newest_release([release("v0.1.21-rc18"), release("v0.1.21-rc17")], "0.1.21-rc17").version == "0.1.21-rc18"
    assert updater.newest_release([release("v0.1.21"), release("v0.1.21-rc18")], "0.1.21-rc17").version == "0.1.21"


def test_drafts_unsigned_and_foreign_assets_are_skipped() -> None:
    assert updater.newest_release([release("v0.2.0", draft=True)], "0.1.0") is None
    assert updater.newest_release([release("v0.2.0", assets=False)], "0.1.0") is None
    assert updater.newest_release([release("v0.2.0", prefix="https://example.com/")], "0.1.0") is None


def test_embedded_public_key_matches_the_mac_app() -> None:
    info = plistlib.loads((ROOT / "mac-app/Info.plist").read_bytes())
    assert updater.UPDATE_PUBLIC_KEY == info["ElinkUpdatePublicKey"]


def _keypair() -> tuple[Ed25519PrivateKey, str]:
    key = Ed25519PrivateKey.generate()
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    public = base64.b64encode(raw).decode()
    return key, public


def test_signature_must_match_the_data() -> None:
    key, public = _keypair()
    signature = base64.b64encode(key.sign(b"package"))
    updater.verify_signature(b"package", signature, public)
    with pytest.raises(UpdateError):
        updater.verify_signature(b"tampered", signature, public)
    with pytest.raises(UpdateError):
        updater.verify_signature(b"package", signature, _keypair()[1])


def _git_archive(tmp_path: Path) -> Path:
    archive = tmp_path / "agent.tar.gz"
    subprocess.run(["git", "archive", "--format=tar.gz", "-o", str(archive), "HEAD", "pyproject.toml", "elink-agent"],
                   cwd=ROOT, check=True)
    return archive


def test_release_archive_extracts_and_matches_its_version(tmp_path: Path) -> None:
    init = subprocess.run(["git", "show", "HEAD:elink-agent/src/elink_agent/__init__.py"], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout
    head_version = re.search(r'^__version__ = "([^"]+)"$', init, re.M).group(1)
    source = updater.extract_source(_git_archive(tmp_path), tmp_path / "source", head_version)
    assert (source / "elink-agent/src/elink_agent/__init__.py").is_file()
    with pytest.raises(UpdateError):
        updater.extract_source(_git_archive(tmp_path), tmp_path / "other", "9.9.9")


@pytest.mark.parametrize("name", ["../escape", "/etc/passwd", "README.md", "elink-agent/../../x"])
def test_archive_with_unexpected_members_is_rejected(tmp_path: Path, name: str) -> None:
    archive = tmp_path / "bad.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        info = tarfile.TarInfo(name)
        info.size = 1
        tar.addfile(info, io.BytesIO(b"x"))
    with pytest.raises(UpdateError):
        updater.extract_source(archive, tmp_path / "source", "0.1.0")
    assert not (tmp_path / "source").exists()


def _source(path: Path, marker: str) -> Path:
    (path / "elink-agent").mkdir(parents=True)
    (path / "elink-agent/marker").write_text(marker)
    (path / "pyproject.toml").write_text(marker)
    return path


def _baseline(tmp_path: Path) -> Path:
    root = tmp_path / "opt"
    _source(root / "source-install", "old")
    (root / "source").symlink_to("source-install")
    return root / "source"


def test_successful_install_atomically_becomes_the_rollback_baseline(tmp_path: Path) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")
    commands: list[list[str]] = []
    Installer(baseline, "python", "url", run=commands.append, healthy=lambda url, v: True).install(new, "0.2.0", "0.1.0")
    assert commands == [["python", "-m", "pip", "install", "--no-deps", "--no-build-isolation", str(new)],
                        ["systemctl", "restart", "elink-agent"]]
    assert baseline.is_symlink() and baseline.readlink() == Path("source-0.2.0")
    assert (baseline / "elink-agent/marker").read_text() == "new"
    assert sorted(p.name for p in baseline.parent.iterdir()) == ["source", "source-0.2.0"]


def test_unhealthy_update_reinstalls_the_baseline(tmp_path: Path) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")
    commands: list[list[str]] = []
    with pytest.raises(UpdateError):
        Installer(baseline, "python", "url", run=commands.append,
                  healthy=lambda url, v: v == "0.1.0").install(new, "0.2.0", "0.1.0")
    assert [c[-1] for c in commands] == [str(new), "elink-agent", str(baseline.resolve()), "elink-agent"]
    assert baseline.readlink() == Path("source-install")


def test_any_failure_during_install_rolls_back(tmp_path: Path) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")
    commands: list[list[str]] = []

    def run(command: list[str]) -> None:
        commands.append(command)
        if command[-1] == str(new):
            raise subprocess.CalledProcessError(1, command)

    with pytest.raises(subprocess.CalledProcessError):
        Installer(baseline, "python", "url", run=run, healthy=lambda url, v: True).install(new, "0.2.0", "0.1.0")
    assert [c[-1] for c in commands] == [str(new), str(baseline.resolve()), "elink-agent"]


@pytest.mark.parametrize(("host", "url"), [
    ("0.0.0.0", "http://127.0.0.1:8766/v1/health"),
    ("::", "http://127.0.0.1:8766/v1/health"),
    ("192.168.1.30", "http://192.168.1.30:8766/v1/health"),
    ("fe80::1", "http://[fe80::1]:8766/v1/health"),
])
def test_health_check_uses_the_listen_address(host: str, url: str) -> None:
    assert updater.health_url(host, 8766) == url


def test_truncated_health_response_counts_as_a_failed_probe(monkeypatch: pytest.MonkeyPatch) -> None:
    def truncated(*_args, **_kwargs):
        raise http.client.IncompleteRead(b"{")

    monkeypatch.setattr(updater.urllib.request, "urlopen", truncated)
    monkeypatch.setattr(updater.time, "sleep", lambda _s: None)
    assert updater.wait_for_version("http://127.0.0.1:1/v1/health", "0.2.0", timeout_s=0.05) is False


def test_update_downloads_verifies_and_installs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    key, public = _keypair()
    monkeypatch.setattr(updater, "UPDATE_PUBLIC_KEY", public)
    version = "99.0.0"
    staging = _source(tmp_path / "pkg", "new")
    (staging / "pyproject.toml").write_text(f'[project]\nversion = "{version}"\n')
    (staging / "elink-agent/src/elink_agent").mkdir(parents=True)
    (staging / "elink-agent/src/elink_agent/__init__.py").write_text(f'__version__ = "{version}"\n')
    archive = tmp_path / "pkg.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(staging / "pyproject.toml", "pyproject.toml")
        tar.add(staging / "elink-agent", "elink-agent")
    data = archive.read_bytes()
    responses = {updater.RELEASES_API: json.dumps([release(f"v{version}")]).encode(),
                 API + "1": data, API + "2": base64.b64encode(key.sign(data))}
    installed: list[str] = []
    record = tmp_path / "update-failed"

    class FakeInstaller:
        def install(self, source: Path, v: str, previous: str) -> None:
            assert (source / "pyproject.toml").exists()
            installed.append(v)

    result = updater.update(work_dir=tmp_path / "work", installer=FakeInstaller(), failed_record=record, current=__version__, running=lambda: True,
                            get=lambda url, **_: responses[url])
    assert result == version and installed == [version]
    assert not (tmp_path / "work").exists()

    responses[API + "2"] = base64.b64encode(key.sign(b"other"))
    with pytest.raises(UpdateError):
        updater.update(work_dir=tmp_path / "work", installer=FakeInstaller(), failed_record=record, current=__version__, running=lambda: True,
                       get=lambda url, **_: responses[url])
    assert installed == [version]


def test_github_prerelease_flag_keeps_final_devices_on_finals() -> None:
    flagged = release("v0.2.0") | {"prerelease": True}
    assert updater.newest_release([flagged], "0.1.0") is None
    assert updater.newest_release([flagged], "0.1.0-rc1").version == "0.2.0"


def test_failed_promotion_rolls_back(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")
    commands: list[list[str]] = []

    def disk_full(*_args, **_kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(updater.shutil, "copytree", disk_full)
    with pytest.raises(OSError):
        Installer(baseline, "python", "url", run=commands.append, healthy=lambda url, v: True).install(new, "0.2.0", "0.1.0")
    assert [c[-1] for c in commands] == [str(new), "elink-agent", str(baseline.resolve()), "elink-agent"]
    assert baseline.readlink() == Path("source-install")


def test_rolled_back_version_is_not_retried(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    key, public = _keypair()
    monkeypatch.setattr(updater, "UPDATE_PUBLIC_KEY", public)
    responses = {updater.RELEASES_API: json.dumps([release("v99.0.0")]).encode()}
    record = tmp_path / "update-failed"
    record.write_text("99.0.0\n")

    def get(url: str, **_kwargs) -> bytes:
        assert url == updater.RELEASES_API, "a rolled-back version must not be downloaded again"
        return responses[url]

    assert updater.update(work_dir=tmp_path / "work", installer=None, failed_record=record,
                          current=__version__, running=lambda: True, get=get) is None


def test_failed_install_records_the_version(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    key, public = _keypair()
    monkeypatch.setattr(updater, "UPDATE_PUBLIC_KEY", public)
    monkeypatch.setattr(updater, "extract_source", lambda archive, dest, version: dest)
    data = b"archive"
    responses = {updater.RELEASES_API: json.dumps([release("v99.0.0")]).encode(),
                 API + "1": data, API + "2": base64.b64encode(key.sign(data))}

    class BrokenInstaller:
        def install(self, source: Path, version: str, previous: str) -> None:
            raise UpdateError("unhealthy")

    record = tmp_path / "update-failed"
    with pytest.raises(UpdateError):
        updater.update(work_dir=tmp_path / "work", installer=BrokenInstaller(), failed_record=record,
                       current=__version__, running=lambda: True, get=lambda url, **_: responses[url])
    assert record.read_text().strip() == "99.0.0"


def test_failed_rollback_is_reported_and_not_recorded(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")

    def run(command: list[str]) -> None:
        if command[0] == "python":
            raise subprocess.CalledProcessError(1, command)

    with pytest.raises(updater.RollbackFailed):
        Installer(baseline, "python", "url", run=run, healthy=lambda url, v: True).install(new, "0.2.0", "0.1.0")

    key, public = _keypair()
    monkeypatch.setattr(updater, "UPDATE_PUBLIC_KEY", public)
    monkeypatch.setattr(updater, "extract_source", lambda archive, dest, version: dest)
    data = b"archive"
    responses = {updater.RELEASES_API: json.dumps([release("v99.0.0")]).encode(),
                 API + "1": data, API + "2": base64.b64encode(key.sign(data))}

    class RollbackBroken:
        def install(self, source: Path, version: str, previous: str) -> None:
            raise updater.RollbackFailed("both failed")

    record = tmp_path / "update-failed"
    with pytest.raises(updater.RollbackFailed):
        updater.update(work_dir=tmp_path / "work", installer=RollbackBroken(), failed_record=record,
                       current=__version__, running=lambda: True, get=lambda url, **_: responses[url])
    assert not record.exists()


def test_rollback_that_does_not_come_back_up_is_reported(tmp_path: Path) -> None:
    baseline, new = _baseline(tmp_path), _source(tmp_path / "new", "new")
    with pytest.raises(updater.RollbackFailed):
        Installer(baseline, "python", "url", run=lambda c: None,
                  healthy=lambda url, v: False).install(new, "0.2.0", "0.1.0")


def test_stopped_agent_is_not_updated(tmp_path: Path) -> None:
    def get(url: str, **_kwargs) -> bytes:
        raise AssertionError("nothing should be downloaded while the agent is stopped")

    assert updater.update(work_dir=tmp_path / "work", installer=None, failed_record=tmp_path / "f",
                          current=__version__, running=lambda: False, get=get) is None


def test_agent_stopped_during_download_is_not_installed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    key, public = _keypair()
    monkeypatch.setattr(updater, "UPDATE_PUBLIC_KEY", public)
    monkeypatch.setattr(updater, "extract_source", lambda archive, dest, version: dest)
    data = b"archive"
    responses = {updater.RELEASES_API: json.dumps([release("v99.0.0")]).encode(),
                 API + "1": data, API + "2": base64.b64encode(key.sign(data))}
    states = iter([True, False])

    class MustNotInstall:
        def install(self, *_args) -> None:
            raise AssertionError("a stopped agent must not be reinstalled or restarted")

    record = tmp_path / "update-failed"
    assert updater.update(work_dir=tmp_path / "work", installer=MustNotInstall(), failed_record=record,
                          current=__version__, running=lambda: next(states),
                          get=lambda url, **_: responses[url]) is None
    assert not record.exists()
