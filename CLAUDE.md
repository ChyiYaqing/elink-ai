# Repository instructions

Follow the existing code style and keep changes scoped to the user's request.
Run the relevant Python and/or Swift tests before committing code changes.

## Release protocol

The macOS GitHub Release is the project's release artifact. A release is not
complete when a tag is pushed; it is complete only after the GitHub Actions
`Release` workflow succeeds and the expected DMG is visible on the GitHub
Release.

When the user asks to "release" without naming a version, use the next patch
version unless the requested changes clearly require a minor or major SemVer
bump. If the intended bump is ambiguous or breaking, confirm the version with
the user before publishing. Never release from an unclean worktree or while
unrelated local changes are present.

### 1. Inspect and choose the version

1. Work from `main`, fetch the remote state, and confirm `main` is up to date
   with `origin/main`.
2. Confirm `git status --short` is empty before starting release-only edits.
3. Find the latest version with `git tag --sort=-version:refname` and review all
   commits since that tag.
4. Choose `X.Y.Z` according to SemVer. The Git tag must be `vX.Y.Z`.
5. Confirm neither the local nor remote repository already has that tag. Never
   move, replace, or force-push a published release tag.

### 2. Prepare the release commit

Update every current-version reference found by searching for the previous
version. At minimum, check these locations:

- `CHANGELOG.md`: add `## X.Y.Z` at the top of the release history. Include only
  non-empty subsections, in this exact order: `Packaging`, `Added`, `Changed`,
  `Fixed`, `Removed`. Every included subsection must contain at least one `- `
  bullet. These notes become the GitHub Release body, so describe user-visible
  outcomes rather than commit messages.
- `mac-app/Info.plist`: set `CFBundleShortVersionString` to `X.Y.Z` and increment
  `CFBundleVersion` by exactly one. The workflow rejects a tag whose version
  differs from `CFBundleShortVersionString`.
- `mac-app/Sources/ElinkAIBridge/LaunchAtLogin.swift`: update the fallback value
  of `AppInfo.version`.
- Swift tests: update hard-coded current-version fixtures such as
  `UpdateChecker(currentVersion:)` where they represent the app's current
  version.
- `README.md`: update versioned DMG command and filename examples.

Do not change `pyproject.toml` merely for the macOS DMG release: its version is
for the separately packaged Python project and is not read by the Release
workflow. Change it only when the Python package itself is intentionally being
released.

Review the complete diff and use the release commit message:

```text
release: vX.Y.Z
```

Do not mix new features or opportunistic fixes into the release commit.

### 3. Validate before tagging

All of the following must pass:

```bash
.venv/bin/pytest -q
(cd mac-app && swift test)
git diff --check
```

Also verify that:

- the changelog contains exactly one `## X.Y.Z` section with categorized notes;
- `CFBundleShortVersionString` is `X.Y.Z` and `CFBundleVersion` increased;
- no stale previous-version references remain in release-related files;
- the release commit contains only intended release preparation changes; and
- `main` still has no unexpected divergence from `origin/main`.

A local `mac-app/build-dmg.sh` run is an optional packaging smoke test. It does
not replace GitHub Actions, which builds both `arm64` and `x86_64` executables
and combines them into the released Universal Binary.

### 4. Publish in order

After the release commit is on `main`, create an annotated tag and push the
branch before the tag:

```bash
git tag -a vX.Y.Z -m 'vX.Y.Z'
git push origin main
git push origin vX.Y.Z
```

Pushing `vX.Y.Z` triggers `.github/workflows/release.yml`. Do not manually
create a competing GitHub Release or upload a locally built single-architecture
DMG. Do not report success immediately after the push.

### 5. Monitor and verify publication

Find and watch the tag's workflow run:

```bash
gh run list --workflow=release.yml --branch vX.Y.Z
gh run watch RUN_ID --exit-status
```

The successful run must have all of these results:

- Swift tests pass on both macOS runners;
- the `arm64` and `x86_64` release binaries build successfully;
- the Universal Binary and DMG steps succeed;
- release notes are extracted from `CHANGELOG.md`; and
- the `Publish DMG` step succeeds.

Finally verify the published release:

```bash
gh release view vX.Y.Z \
  --json tagName,name,isDraft,isPrerelease,url,publishedAt,assets
```

The release must be published (not a draft or prerelease unless explicitly
requested) and must contain exactly the expected versioned installer:
`elink-ai-vX.Y.Z.dmg`.

Only then tell the user that the release succeeded, and include links to both
the GitHub Release and the DMG asset. If the workflow fails, report the failing
job and step, fix the underlying issue when it is in scope, and rerun the
workflow. Do not rewrite an already-published tag to hide a failure.
