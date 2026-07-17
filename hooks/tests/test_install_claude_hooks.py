import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "install-claude-hooks.py"


def run_installer(settings_path: Path, helper_dir: Path,
                  check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--settings", str(settings_path), "--helper-dir", str(helper_dir)],
        check=check,
        capture_output=True,
        text=True,
    )


def test_installer_registers_permission_and_elicitation_events(tmp_path):
    settings_path = tmp_path / "settings.json"
    run_installer(settings_path, tmp_path / "helper")
    hooks = json.loads(settings_path.read_text())["hooks"]
    for event in ("PermissionRequest", "Elicitation"):
        assert event in hooks
        assert f"claude {event}" in json.dumps(hooks[event])


def test_installer_is_idempotent_and_preserves_existing_hooks(tmp_path):
    settings_path = tmp_path / "settings.json"
    settings_path.write_text(json.dumps({
        "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "echo existing"}]}]}
    }))
    run_installer(settings_path, tmp_path / "helper")
    run_installer(settings_path, tmp_path / "helper")
    stop_hooks = json.loads(settings_path.read_text())["hooks"]["Stop"]
    assert any("echo existing" in json.dumps(entry) for entry in stop_hooks)
    elink_entries = [entry for entry in stop_hooks if "elink-hook.py" in json.dumps(entry)]
    assert len(elink_entries) == 1


def test_installer_treats_empty_settings_file_as_fresh(tmp_path):
    settings_path = tmp_path / "settings.json"
    settings_path.write_text("")
    run_installer(settings_path, tmp_path / "helper")
    assert "Stop" in json.loads(settings_path.read_text())["hooks"]


def test_installer_replaces_null_hooks_with_object(tmp_path):
    settings_path = tmp_path / "settings.json"
    settings_path.write_text('{"hooks": null}')
    run_installer(settings_path, tmp_path / "helper")
    assert "Stop" in json.loads(settings_path.read_text())["hooks"]


def test_installer_refuses_to_overwrite_malformed_settings(tmp_path):
    settings_path = tmp_path / "settings.json"
    settings_path.write_text('{"hooks": ')
    result = run_installer(settings_path, tmp_path / "helper", check=False)
    assert result.returncode != 0
    assert "not valid JSON" in result.stderr
    assert settings_path.read_text() == '{"hooks": '
