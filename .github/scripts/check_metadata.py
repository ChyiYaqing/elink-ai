#!/usr/bin/env python3
"""Validate repository metadata, plist files, version parity, and release readiness."""

from __future__ import annotations

import argparse
import base64
import plistlib
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Match elink_agent.updater._VERSION so published tags are always parseable by devices.
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$")
CHANGELOG_SECTIONS = ("Packaging", "Added", "Changed", "Fixed", "Removed")


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def parse_version(text: str) -> tuple[int, int, int, int, int] | None:
    match = VERSION_RE.fullmatch(text)
    if not match:
        return None
    major, minor, patch, rc = match.groups()
    if rc is None:
        return (int(major), int(minor), int(patch), 1, 0)
    return (int(major), int(minor), int(patch), 0, int(rc))


def load_plist(path: Path, errors: list[str]) -> dict | None:
    try:
        with path.open("rb") as fh:
            data = plistlib.load(fh)
        if not isinstance(data, dict):
            fail(errors, f"{path.relative_to(ROOT)}: root plist object is not a dict")
            return None
        return data
    except Exception as exc:  # pragma: no cover - defensive report
        fail(errors, f"{path.relative_to(ROOT)}: invalid plist ({exc})")
        return None


def validate_ed25519_key(value: str, label: str, errors: list[str]) -> bool:
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        fail(errors, f"{label}: invalid base64 ({exc})")
        return False
    if len(raw) != 32:
        fail(errors, f"{label}: expected 32-byte Ed25519 public key, got {len(raw)} bytes")
        return False
    return True


def read_versions(info_plist: dict | None, errors: list[str]) -> tuple[dict[str, str], int | None]:
    versions: dict[str, str] = {}
    bundle_version: int | None = None

    if info_plist is not None:
        short_ver = info_plist.get("CFBundleShortVersionString")
        bundle_ver = info_plist.get("CFBundleVersion")
        if isinstance(short_ver, str) and short_ver:
            versions["mac-app/Info.plist"] = short_ver
        else:
            fail(errors, "mac-app/Info.plist: missing CFBundleShortVersionString")
        if isinstance(bundle_ver, str) and bundle_ver.isdigit() and int(bundle_ver) > 0:
            bundle_version = int(bundle_ver)
        else:
            fail(errors, f"mac-app/Info.plist: CFBundleVersion must be a positive integer, got {bundle_ver!r}")

    cargo_toml = tomllib.loads((ROOT / "elink-tui/Cargo.toml").read_text(encoding="utf-8"))
    versions["elink-tui/Cargo.toml"] = str(cargo_toml["package"]["version"])

    cargo_lock = tomllib.loads((ROOT / "elink-tui/Cargo.lock").read_text(encoding="utf-8"))
    lock_matches = [
        str(pkg["version"])
        for pkg in cargo_lock.get("package", [])
        if pkg.get("name") == "elink-tui"
    ]
    if len(lock_matches) == 1:
        versions["elink-tui/Cargo.lock"] = lock_matches[0]
    else:
        fail(errors, f"elink-tui/Cargo.lock: expected 1 elink-tui package entry, found {len(lock_matches)}")

    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    versions["pyproject.toml"] = str(pyproject["project"]["version"])

    init_text = (ROOT / "elink-agent/src/elink_agent/__init__.py").read_text(encoding="utf-8")
    init_match = re.search(r'^__version__\s*=\s*"([^"]+)"', init_text, re.MULTILINE)
    if init_match:
        versions["elink-agent/src/elink_agent/__init__.py"] = init_match.group(1)
    else:
        fail(errors, "elink-agent/src/elink_agent/__init__.py: __version__ not found")

    launch_text = (ROOT / "mac-app/Sources/ElinkAIBridge/LaunchAtLogin.swift").read_text(encoding="utf-8")
    launch_match = re.search(
        r'static\s+let\s+version\s*=.*?\?\?\s*"([^"]+)"',
        launch_text,
        re.DOTALL,
    )
    if launch_match:
        versions["mac-app/Sources/ElinkAIBridge/LaunchAtLogin.swift"] = launch_match.group(1)
    else:
        fail(errors, "mac-app/Sources/ElinkAIBridge/LaunchAtLogin.swift: AppInfo.version fallback not found")

    return versions, bundle_version


def find_previous_release_tag(target_version: str, errors: list[str]) -> str | None:
    target_key = parse_version(target_version)
    if target_key is None:
        return None
    proc = subprocess.run(
        ["git", "tag", "--list", "v*"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        fail(errors, f"git tag --list failed: {proc.stderr.strip()}")
        return None

    candidates: list[tuple[tuple[int, int, int, int, int], str]] = []
    for tag in proc.stdout.splitlines():
        tag = tag.strip()
        if not tag.startswith("v"):
            continue
        key = parse_version(tag[1:])
        if key is not None and key < target_key:
            candidates.append((key, tag))

    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    return candidates[-1][1]


def load_plist_from_git(ref: str, rel_path: str, errors: list[str]) -> dict | None:
    proc = subprocess.run(
        ["git", "show", f"{ref}:{rel_path}"],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        fail(errors, f"git show {ref}:{rel_path} failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
        return None
    try:
        data = plistlib.loads(proc.stdout)
    except Exception as exc:
        fail(errors, f"{ref}:{rel_path}: invalid plist ({exc})")
        return None
    if not isinstance(data, dict):
        fail(errors, f"{ref}:{rel_path}: root plist object is not a dict")
        return None
    return data


def check_signing_keys(info_plist: dict | None, errors: list[str]) -> tuple[str | None, str | None]:
    plist_key = info_plist.get("ElinkUpdatePublicKey") if info_plist else None
    if not isinstance(plist_key, str) or not plist_key:
        fail(errors, "mac-app/Info.plist: missing ElinkUpdatePublicKey")
        plist_key = None
    else:
        validate_ed25519_key(plist_key, "mac-app/Info.plist:ElinkUpdatePublicKey", errors)

    updater_text = (ROOT / "elink-agent/src/elink_agent/updater.py").read_text(encoding="utf-8")
    updater_match = re.search(r'^UPDATE_PUBLIC_KEY\s*=\s*"([^"]+)"', updater_text, re.MULTILINE)
    if not updater_match:
        fail(errors, "elink-agent/src/elink_agent/updater.py: UPDATE_PUBLIC_KEY not found")
        updater_key = None
    else:
        updater_key = updater_match.group(1)
        validate_ed25519_key(updater_key, "elink-agent/src/elink_agent/updater.py:UPDATE_PUBLIC_KEY", errors)

    if plist_key and updater_key and plist_key != updater_key:
        fail(
            errors,
            "ElinkUpdatePublicKey in mac-app/Info.plist does not match UPDATE_PUBLIC_KEY in updater.py",
        )

    signing_key = (ROOT / "mac-app/update-signing-public-key").read_text(encoding="utf-8").strip()
    valid_signing = validate_ed25519_key(signing_key, "mac-app/update-signing-public-key", errors)
    if valid_signing and plist_key and signing_key != plist_key:
        print(
            "NOTE: mac-app/update-signing-public-key differs from Info.plist ElinkUpdatePublicKey "
            "(expected only during a key-rotation transition release)."
        )
    return plist_key, signing_key if valid_signing else None


def check_previous_release(
    target_version: str,
    bundle_version: int | None,
    signing_key: str | None,
    errors: list[str],
) -> None:
    prev_tag = find_previous_release_tag(target_version, errors)
    if prev_tag is None:
        fail(
            errors,
            f"No previous release tag found before v{target_version} "
            "(ensure git tags are fetched with fetch-depth: 0).",
        )
        return

    prev_plist = load_plist_from_git(prev_tag, "mac-app/Info.plist", errors)
    if prev_plist is None:
        return

    prev_bundle_raw = prev_plist.get("CFBundleVersion")
    if isinstance(prev_bundle_raw, str) and prev_bundle_raw.isdigit():
        prev_bundle = int(prev_bundle_raw)
        if bundle_version is not None and bundle_version != prev_bundle + 1:
            fail(
                errors,
                f"mac-app/Info.plist: CFBundleVersion is {bundle_version}, expected {prev_bundle + 1} "
                f"(previous release {prev_tag} had {prev_bundle})",
            )
    else:
        fail(errors, f"{prev_tag}:mac-app/Info.plist has non-integer CFBundleVersion {prev_bundle_raw!r}")

    prev_embedded_key = prev_plist.get("ElinkUpdatePublicKey")
    if isinstance(prev_embedded_key, str) and prev_embedded_key and signing_key:
        if signing_key != prev_embedded_key:
            fail(
                errors,
                f"mac-app/update-signing-public-key does not match {prev_tag}'s ElinkUpdatePublicKey; "
                "installed clients trust the previous release's embedded key and would reject this update",
            )


def check_changelog(version: str, errors: list[str]) -> None:
    lines = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
    header = f"## {version}"
    header_indices = [idx for idx, line in enumerate(lines) if line == header]
    if len(header_indices) != 1:
        fail(errors, f"CHANGELOG.md: expected exactly one '{header}' heading, found {len(header_indices)}")
        return

    start = header_indices[0] + 1
    end = len(lines)
    for idx in range(start, len(lines)):
        if lines[idx].startswith("## "):
            end = idx
            break
    section_lines = lines[start:end]

    subsections: list[tuple[str, int]] = []
    current_sub: str | None = None
    bullet_counts: dict[str, int] = {}

    for line in section_lines:
        if line.startswith("### "):
            name = line[4:].strip()
            if name not in CHANGELOG_SECTIONS:
                fail(
                    errors,
                    f"CHANGELOG.md ({header}): invalid subsection '### {name}' "
                    f"(allowed: {', '.join(CHANGELOG_SECTIONS)})",
                )
                current_sub = None
                continue
            if name in bullet_counts:
                fail(errors, f"CHANGELOG.md ({header}): duplicate subsection '### {name}'")
            subsections.append((name, CHANGELOG_SECTIONS.index(name)))
            bullet_counts[name] = 0
            current_sub = name
        elif line.startswith("- "):
            if current_sub is None:
                fail(errors, f"CHANGELOG.md ({header}): bullet appears before any ### subsection")
            else:
                bullet_counts[current_sub] += 1

    if not subsections:
        fail(errors, f"CHANGELOG.md ({header}): missing categorized ### subsections")
        return

    order_indices = [idx for _, idx in subsections]
    if order_indices != sorted(order_indices):
        names = ", ".join(name for name, _ in subsections)
        fail(
            errors,
            f"CHANGELOG.md ({header}): subsections out of order ({names}); "
            f"expected order: {', '.join(CHANGELOG_SECTIONS)}",
        )

    for name, count in bullet_counts.items():
        if count == 0:
            fail(errors, f"CHANGELOG.md ({header}): subsection '### {name}' has no '- ' bullets")


def check_readme(version: str, errors: list[str]) -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    expected_dmg = f"elink-ai-v{version}.dmg"
    if expected_dmg not in readme:
        fail(errors, f"README.md: expected versioned DMG example '{expected_dmg}'")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--release-version",
        help="Target release version (e.g. 0.1.22, 0.1.22-rc1, or v0.1.22) to enforce against all version fields.",
    )
    parser.add_argument(
        "--check-changelog",
        action="store_true",
        help="Validate that CHANGELOG.md has a properly formatted section for the target version.",
    )
    parser.add_argument(
        "--check-readme",
        action="store_true",
        help="Validate that README.md references the target version's DMG filename.",
    )
    parser.add_argument(
        "--check-prev-release",
        action="store_true",
        help="Verify CFBundleVersion incremented by 1 and update-signing-public-key matches the previous release tag.",
    )
    args = parser.parse_args()

    errors: list[str] = []

    info_plist = load_plist(ROOT / "mac-app/Info.plist", errors)
    for example_plist in sorted((ROOT / "install").glob("*.plist.example")):
        load_plist(example_plist, errors)

    versions, bundle_version = read_versions(info_plist, errors)
    for source, ver in versions.items():
        if parse_version(ver) is None:
            fail(errors, f"{source}: '{ver}' must match X.Y.Z or X.Y.Z-rcN")

    unique_versions = sorted(set(versions.values()))
    if len(unique_versions) > 1:
        details = ", ".join(f"{src}={ver}" for src, ver in versions.items())
        fail(errors, f"Version mismatch across repository files: {details}")

    target_version: str | None = None
    if args.release_version is not None:
        raw_target = args.release_version.strip()
        target_version = raw_target.removeprefix("v")
        if not target_version or parse_version(target_version) is None:
            fail(errors, f"--release-version '{args.release_version}' must match X.Y.Z or X.Y.Z-rcN")
            target_version = None
        else:
            for source, ver in versions.items():
                if ver != target_version:
                    fail(errors, f"{source}: version '{ver}' does not match target '{target_version}'")
    elif unique_versions:
        target_version = unique_versions[0]

    _, signing_key = check_signing_keys(info_plist, errors)

    if args.check_prev_release and target_version:
        check_previous_release(target_version, bundle_version, signing_key, errors)

    if args.check_changelog and target_version:
        check_changelog(target_version, errors)

    if args.check_readme and target_version:
        check_readme(target_version, errors)

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"Metadata checks passed (version={target_version}, checked {len(versions)} version locations).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
