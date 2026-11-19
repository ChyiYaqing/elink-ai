# Repository instructions

Follow the existing code style and keep changes scoped to the user's request.
Run the relevant Python, Swift, and/or Rust (`cd elink-tui && cargo test`)
tests before committing code changes.

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
- `elink-tui/Cargo.toml`: set `version` to `X.Y.Z`, then refresh
  `elink-tui/Cargo.lock` (any cargo command rewrites it). The workflow rejects a
  tag whose version differs from this one, and both Linux TUI jobs fail before
  building anything.
- Swift tests: update hard-coded current-version fixtures such as
  `UpdateChecker(currentVersion:)` where they represent the app's current
  version.
- `README.md`: update versioned DMG command and filename examples.

Searching for the previous version string is not enough on its own: run
`git show --stat vPREVIOUS` and confirm the new release commit touches the same
set of files. v0.1.17-rc8 failed because a search restricted to `*.swift`,
`*.md` and `*.plist` never looked at `.toml`, and the missing Cargo bump was
only caught by CI after the tag was already pushed.

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
(cd elink-tui && cargo test)
git diff --check
```

Replay the workflow's two version gates locally before tagging; both reject the
tag outright, so a mismatch costs a whole release cycle:

```bash
VERSION=X.Y.Z
[ "$VERSION" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' mac-app/Info.plist)" ]
[ "$VERSION" = "$(sed -n 's/^version = "\([^"]*\)"$/\1/p' elink-tui/Cargo.toml)" ]
```

Also verify that:

- the changelog contains exactly one `## X.Y.Z` section with categorized notes;
- `CFBundleShortVersionString` is `X.Y.Z` and `CFBundleVersion` increased;
- no stale previous-version references remain in release-related files;
- the release commit contains only intended release preparation changes; and
- `main` still has no unexpected divergence from `origin/main`.

A local `mac-app/build-dmg.sh` run is an optional packaging smoke test. It does
not replace GitHub Actions. The Release workflow runs on the `MacMiniM4`
self-hosted runner selected by `[self-hosted, macOS, ARM64, elink-ci]`, builds
the `arm64` executable natively, cross-compiles the `x86_64` executable with an
explicit macOS target triple, and combines them into the released Universal
Binary. Keep the architecture checks in the workflow; the Intel build must be
verified with `lipo` even when a physical Intel Mac will be used for final
manual validation.

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

- Swift tests pass in both architecture build jobs on the self-hosted runner;
- the `arm64` and `x86_64` release binaries build successfully;
- the Universal Binary and DMG steps succeed;
- the `Sign update DMG` step succeeds;
- release notes are extracted from `CHANGELOG.md`; and
- the `Publish DMG` step succeeds.

Finally verify the published release:

```bash
gh release view vX.Y.Z \
  --json tagName,name,isDraft,isPrerelease,url,publishedAt,assets
```

The release must be published (not a draft or prerelease unless explicitly
requested) and must contain exactly the expected versioned installer
`elink-ai-vX.Y.Z.dmg` and its update signature `elink-ai-vX.Y.Z.dmg.sig`.

Only then tell the user that the release succeeded, and include links to both
the GitHub Release and the DMG asset. If the workflow fails, report the failing
job and step, fix the underlying issue when it is in scope, and rerun the
workflow. Do not rewrite an already-published tag to hide a failure.

### Update signing key

In-app updates only install a DMG whose Ed25519 signature matches
`ElinkUpdatePublicKey` in the installed app's `mac-app/Info.plist`. The private
key (Base64 of the raw 32 bytes) is the repository secret
`ELINK_UPDATE_SIGNING_KEY`. The `Sign update DMG` step fails when the secret is
missing or does not match `mac-app/update-signing-public-key`, the public key
that installed apps currently trust. Normally that file and
`ElinkUpdatePublicKey` hold the same value.

To rotate the key, publish a transition release that is still signed with the
old secret and `update-signing-public-key`, but whose `ElinkUpdatePublicKey` is
the new public key. After that release, switch the secret and
`update-signing-public-key` to the new key. Apps always offer the newest
release, so clients that never installed the transition release fail signature
verification and must install manually once, the same as when the private key
is lost. Rotate only when necessary.
