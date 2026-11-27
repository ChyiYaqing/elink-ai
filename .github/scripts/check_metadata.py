#!/usr/bin/env python3
"""Validate repository metadata, plist files, version parity, and release readiness."""

from __future__ import annotations

import argparse
import base64
import plistlib
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
CHANGELOG_SECTIONS = ("Packaging", "Added", "Changed", "Fixed", "Removed")


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


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


def read_versions(info_plist: dict | None, errors: list[str]) -> dict[str, str]:
    versions: dict[str, str] = {}

    if info_plist is not None:
        short_ver = info_plist.get("CFBundleShortVersionString")
        bundle_ver = info_plist.get("CFBundleVersion")
        if isinstance(short_ver, str) and short_ver:
            versions["mac-app/Info.plist"] = short_ver
        else:
            fail(errors, "mac-app/Info.plist: missing CFBundleShortVersionString")
        if not (isinstance(bundle_ver, str) and bundle_ver.isdigit() and int(bundle_ver) > 0):
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

    return versions


def check_signing_keys(info_plist: dict | None, errors: list[str]) -> None:
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
    if validate_ed25519_key(signing_key, "mac-app/update-signing-public-key", errors):
        if plist_key and signing_key != plist_key:
            print(
                "NOTE: mac-app/update-signing-public-key differs from Info.plist ElinkUpdatePublicKey "
                "(expected only during a key-rotation transition release)."
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
        help="Target release version (e.g. 0.1.22 or v0.1.22) to enforce against all version fields.",
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
    args = parser.parse_args()

    errors: list[str] = []

    info_plist = load_plist(ROOT / "mac-app/Info.plist", errors)
    for example_plist in sorted((ROOT / "install").glob("*.plist.example")):
        load_plist(example_plist, errors)

    versions = read_versions(info_plist, errors)
    for source, ver in versions.items():
        if not SEMVER_RE.match(ver):
            fail(errors, f"{source}: '{ver}' is not a valid SemVer string")

    unique_versions = sorted(set(versions.values()))
    if len(unique_versions) > 1:
        details = ", ".join(f"{src}={ver}" for src, ver in versions.items())
        fail(errors, f"Version mismatch across repository files: {details}")

    target_version: str | None = None
    if args.release_version:
        target_version = args.release_version.removeprefix("v")
        if not SEMVER_RE.match(target_version):
            fail(errors, f"--release-version '{args.release_version}' is not valid SemVer")
        for source, ver in versions.items():
            if ver != target_version:
                fail(errors, f"{source}: version '{ver}' does not match target '{target_version}'")
    elif unique_versions:
        target_version = unique_versions[0]

    check_signing_keys(info_plist, errors)

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
