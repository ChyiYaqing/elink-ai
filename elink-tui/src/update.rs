use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const REPO: &str = "ChyiYaqing/elink-ai";
pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, PartialEq)]
pub struct UpdateInfo {
    pub tag: String,
    pub url: String,
    pub newer: bool,
}

#[derive(Default)]
pub enum UpdateSlot {
    #[default]
    Idle,
    Checking,
    Done(Result<UpdateInfo, String>),
}

pub type SharedUpdate = Arc<Mutex<UpdateSlot>>;

/// Queries the newest stable GitHub release off-thread; the UI polls the
/// slot. Release candidates are published as prereleases and are skipped.
pub fn spawn_check(slot: SharedUpdate) {
    {
        let mut guard = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if matches!(*guard, UpdateSlot::Checking) {
            return;
        }
        *guard = UpdateSlot::Checking;
    }
    thread::spawn(move || {
        let result = fetch_latest();
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = UpdateSlot::Done(result);
    });
}

/// Anonymous API first; private repositories 404 anonymously, so fall back
/// to the user's existing `gh auth login` session (mirrors UpdateChecker's
/// GitHub CLI fallback — no token is copied or stored).
fn fetch_latest() -> Result<UpdateInfo, String> {
    let api_error = match fetch_via_api() {
        Ok(info) => return Ok(info),
        Err(error) => error,
    };
    match fetch_via_gh() {
        Ok(info) => Ok(info),
        Err(GhError::Unavailable) if api_error.contains("404") => {
            Err("private repository: install GitHub CLI and run gh auth login".to_string())
        }
        Err(GhError::Unavailable) => Err(api_error),
        Err(GhError::Failed(detail)) => Err(detail),
    }
}

fn fetch_via_api() -> Result<UpdateInfo, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    let response = agent
        .get(&format!(
            "https://api.github.com/repos/{REPO}/releases?per_page=20"
        ))
        .set("User-Agent", &format!("elink-tui/{CURRENT_VERSION}"))
        .set("Accept", "application/vnd.github+json")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .call()
        .map_err(|error| match error {
            ureq::Error::Status(code, _) => format!("update check HTTP {code}"),
            ureq::Error::Transport(_) => "update check request failed".to_string(),
        })?;
    let json: serde_json::Value = response
        .into_json()
        .map_err(|_| "update check response parse failed".to_string())?;
    release_info(&json).ok_or_else(|| "no published releases found".to_string())
}

enum GhError {
    Unavailable,
    Failed(String),
}

fn fetch_via_gh() -> Result<UpdateInfo, GhError> {
    let output = std::process::Command::new("gh")
        .args(["api", &format!("repos/{REPO}/releases?per_page=20")])
        .output()
        .map_err(|_| GhError::Unavailable)?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim();
        return Err(GhError::Failed(if detail.is_empty() {
            "GitHub CLI authentication failed".to_string()
        } else {
            format!("GitHub CLI: {}", detail.lines().next().unwrap_or_default())
        }));
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| GhError::Failed("GitHub CLI response parse failed".to_string()))?;
    release_info(&json).ok_or_else(|| GhError::Failed("no published releases found".to_string()))
}

/// Picks the highest stable (non-draft, non-prerelease) version from a
/// GitHub `/releases` listing and compares it against the running version.
pub fn release_info(releases: &serde_json::Value) -> Option<UpdateInfo> {
    let mut best: Option<(ParsedVersion, UpdateInfo)> = None;
    for release in releases.as_array()? {
        if release.get("draft").and_then(serde_json::Value::as_bool) == Some(true)
            || release
                .get("prerelease")
                .and_then(serde_json::Value::as_bool)
                == Some(true)
        {
            continue;
        }
        let Some(tag) = release.get("tag_name").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let Some(parsed) = parse_version(tag) else {
            continue;
        };
        if best
            .as_ref()
            .is_none_or(|(best_parsed, _)| ranking(parsed) > ranking(*best_parsed))
        {
            let url = release
                .get("html_url")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("https://github.com/ChyiYaqing/elink-ai/releases")
                .to_string();
            let newer = is_newer(CURRENT_VERSION, tag).unwrap_or(false);
            best = Some((
                parsed,
                UpdateInfo {
                    tag: tag.to_string(),
                    url,
                    newer,
                },
            ));
        }
    }
    best.map(|(_, info)| info)
}

/// `vX.Y.Z` / `X.Y.Z-rcN` comparison: numeric core first, then a release
/// outranks its own release candidates, and candidates compare numerically.
pub fn is_newer(current: &str, latest: &str) -> Option<bool> {
    let current = parse_version(current)?;
    let latest = parse_version(latest)?;
    Some(ranking(latest) > ranking(current))
}

type ParsedVersion = ([u64; 3], Option<u64>);

/// Total order where a release outranks its own candidates: rc N maps below
/// the plain release of the same core version.
fn ranking(version: ParsedVersion) -> ([u64; 3], (u8, u64)) {
    let prerelease = match version.1 {
        None => (1, 0),
        Some(rc) => (0, rc),
    };
    (version.0, prerelease)
}

fn parse_version(value: &str) -> Option<ParsedVersion> {
    let value = value.trim().trim_start_matches('v');
    let (core, prerelease) = match value.split_once('-') {
        Some((core, prerelease)) => (core, Some(prerelease)),
        None => (value, None),
    };
    let mut parts = core.split('.');
    let mut numbers = [0u64; 3];
    for slot in &mut numbers {
        *slot = parts.next()?.parse().ok()?;
    }
    if parts.next().is_some() {
        return None;
    }
    let rc = match prerelease {
        Some(prerelease) => Some(
            prerelease
                .trim_start_matches(|character: char| !character.is_ascii_digit())
                .parse()
                .ok()?,
        ),
        None => None,
    };
    Some((numbers, rc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_release_versions_numerically() {
        assert_eq!(is_newer("0.1.15", "v0.1.16"), Some(true));
        assert_eq!(is_newer("v0.1.16", "v0.1.15"), Some(false));
        assert_eq!(is_newer("0.1.15", "0.1.15"), Some(false));
        assert_eq!(is_newer("0.9.9", "1.0.0"), Some(true));
    }

    #[test]
    fn release_outranks_its_candidates() {
        assert_eq!(is_newer("0.1.15-rc1", "v0.1.15"), Some(true));
        assert_eq!(is_newer("0.1.15", "v0.1.15-rc2"), Some(false));
        assert_eq!(is_newer("0.1.15-rc1", "v0.1.15-rc2"), Some(true));
        assert_eq!(is_newer("0.1.15-rc2", "v0.1.15-rc1"), Some(false));
    }

    #[test]
    fn rejects_malformed_versions() {
        assert_eq!(is_newer("0.1", "v0.1.15"), None);
        assert_eq!(is_newer("0.1.15", "latest"), None);
        assert_eq!(is_newer("0.1.15", "v0.1.15.2"), None);
    }

    #[test]
    fn release_info_picks_highest_stable_release() {
        let releases = serde_json::json!([
            {"tag_name": "v0.2.0-rc1", "prerelease": true, "html_url": "https://x/rc"},
            {"tag_name": "v0.1.99", "draft": true, "html_url": "https://x/draft"},
            {"tag_name": "v0.1.14", "prerelease": false, "html_url": "https://x/14"},
            {"tag_name": "v0.1.17", "prerelease": false, "html_url": "https://x/17"},
            {"tag_name": "not-a-version", "prerelease": false, "html_url": "https://x/bad"}
        ]);

        let info = release_info(&releases).expect("stable release found");

        assert_eq!(info.tag, "v0.1.17");
        assert_eq!(info.url, "https://x/17");
        assert!(info.newer, "0.1.17 outranks the running release");
        assert_eq!(release_info(&serde_json::json!([])), None);
    }
}
