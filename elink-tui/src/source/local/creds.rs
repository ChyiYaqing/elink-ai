use std::env;
use std::fs;
use std::path::Path;

use base64::Engine;

/// Claude token: `CLAUDE_CODE_OAUTH_TOKEN` env first, then
/// `<claude_home>/.credentials.json` -> `claudeAiOauth.accessToken`.
/// Linux has no Keychain path, which is the only macOS-specific fallback.
pub fn claude_token(claude_home: &Path) -> Result<String, String> {
    if let Ok(token) = env::var("CLAUDE_CODE_OAUTH_TOKEN") {
        if !token.is_empty() {
            return Ok(token);
        }
    }
    let path = claude_home.join(".credentials.json");
    let data = fs::read(&path)
        .map_err(|_| "claude credentials not found; run claude to log in".to_string())?;
    let json: serde_json::Value = serde_json::from_slice(&data)
        .map_err(|_| "claude credentials invalid; run claude to log in".to_string())?;
    match json["claudeAiOauth"]["accessToken"].as_str() {
        Some(token) if !token.is_empty() => Ok(token.to_string()),
        _ => Err("claude credentials invalid; run claude to log in".to_string()),
    }
}

/// Codex token and account id from `<codex_home>/auth.json`. The account id
/// comes from `tokens.account_id`, else from the `id_token` JWT claim.
pub fn codex_credentials(codex_home: &Path) -> Result<(String, Option<String>), String> {
    let path = codex_home.join("auth.json");
    let data = fs::read(&path)
        .map_err(|_| "codex auth.json not found; run codex to log in".to_string())?;
    codex_credentials_from(&data, crate::util::epoch_now())
}

/// The access token is a JWT carrying `exp` — observed lifetime is ten days,
/// renewed by the codex CLI itself. Ten days without opening codex and it is
/// dead, and sending a token known to be expired only buys a 401: a wasted
/// round trip that also reports "usage endpoint error" for what is really an
/// expired login. The panel falls back to the windows found in session logs.
pub fn codex_credentials_from(data: &[u8], now: i64) -> Result<(String, Option<String>), String> {
    let json: serde_json::Value = serde_json::from_slice(data)
        .map_err(|_| "codex credentials invalid; run codex to log in".to_string())?;
    let tokens = &json["tokens"];
    let token = match tokens["access_token"].as_str() {
        Some(value) if !value.is_empty() => value.to_string(),
        _ => return Err("codex credentials invalid; run codex to log in".to_string()),
    };
    if !jwt_is_usable(&token, now) {
        return Err("codex credentials expired; run codex to log in".to_string());
    }
    let account = tokens["account_id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| tokens["id_token"].as_str().and_then(account_id));
    Ok((token, account))
}

#[derive(Debug, Clone, PartialEq)]
pub struct GeminiCredentials {
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub expires_at: Option<i64>,
}

impl GeminiCredentials {
    pub fn access_token_usable(&self, now: i64) -> Option<&str> {
        let token = self.access_token.as_deref().filter(|value| !value.is_empty())?;
        match self.expires_at {
            Some(expiry) if expiry - now <= 60 => None,
            _ => Some(token),
        }
    }
}

/// Gemini CLI OAuth credentials from `GOOGLE_CLOUD_ACCESS_TOKEN` or
/// `<gemini_home>/oauth_creds.json`. Returns `Ok(None)` when Gemini CLI is
/// not configured on this host so users without Gemini do not see errors.
pub fn gemini_credentials(gemini_home: &Path) -> Result<Option<GeminiCredentials>, String> {
    if let Ok(token) = env::var("GOOGLE_CLOUD_ACCESS_TOKEN") {
        if !token.is_empty() {
            return Ok(Some(GeminiCredentials {
                access_token: Some(token),
                refresh_token: None,
                expires_at: None,
            }));
        }
    }
    let path = gemini_home.join("oauth_creds.json");
    let data = match fs::read(&path) {
        Ok(data) => data,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => {
            return Err("gemini oauth_creds.json unreadable; run gemini to log in".to_string())
        }
    };
    gemini_credentials_from(&data).map(Some)
}

pub fn gemini_credentials_from(data: &[u8]) -> Result<GeminiCredentials, String> {
    let json: serde_json::Value = serde_json::from_slice(data)
        .map_err(|_| "gemini credentials invalid; run gemini to log in".to_string())?;
    let access_token = json["access_token"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let refresh_token = json["refresh_token"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if access_token.is_none() && refresh_token.is_none() {
        return Err("gemini credentials invalid; run gemini to log in".to_string());
    }
    let expires_at = json["expiry_date"].as_f64().map(|raw| {
        if raw > 10_000_000_000.0 {
            (raw / 1000.0) as i64
        } else {
            raw as i64
        }
    });
    Ok(GeminiCredentials {
        access_token,
        refresh_token,
        expires_at,
    })
}

/// A token without `exp` counts as usable: not every issuer sets the claim, and
/// discarding the only credential over a missing field helps no one. 60 s of
/// slack keeps a request from being spent right on the expiry boundary.
pub fn jwt_is_usable(jwt: &str, now: i64) -> bool {
    match jwt_claims(jwt).and_then(|claims| claims["exp"].as_f64()) {
        Some(expiry) => expiry - now as f64 > 60.0,
        None => true,
    }
}

/// Decodes the JWT payload (base64url, no signature check) and reads
/// `https://api.openai.com/auth.chatgpt_account_id`.
pub fn account_id(jwt: &str) -> Option<String> {
    jwt_claims(jwt)?["https://api.openai.com/auth"]["chatgpt_account_id"]
        .as_str()
        .map(str::to_string)
}

/// The JWT payload segment. Not signature-checked: we only read claims the
/// issuer wrote for us and never authorize anything on their strength.
fn jwt_claims(jwt: &str) -> Option<serde_json::Value> {
    let payload = jwt.split('.').nth(1)?;
    let mut value = payload.replace('-', "+").replace('_', "/");
    while value.len() % 4 != 0 {
        value.push('=');
    }
    let data = base64::engine::general_purpose::STANDARD
        .decode(value)
        .ok()?;
    serde_json::from_slice(&data).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    #[test]
    fn decodes_account_id_from_jwt() {
        let payload = serde_json::json!({
            "https://api.openai.com/auth": {"chatgpt_account_id": "acct-123"}
        });
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(payload.to_string());
        let jwt = format!("eyJhbGciOiJub25lIn0.{encoded}.signature");
        assert_eq!(account_id(&jwt), Some("acct-123".to_string()));
    }

    /// The codex access token is a JWT carrying `exp`. A token known to be dead
    /// must not be sent: the 401 it earns reports "usage endpoint error" for
    /// what is really an expired login, and wastes a round trip.
    #[test]
    fn expired_codex_token_is_recognised_before_any_request() {
        const NOW: i64 = 1_800_000_000;
        fn auth(exp: Option<i64>) -> Vec<u8> {
            let mut claims = serde_json::json!({
                "https://api.openai.com/auth": {"chatgpt_account_id": "acct-123"}
            });
            if let Some(exp) = exp {
                claims["exp"] = serde_json::json!(exp);
            }
            let encoded =
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string());
            let jwt = format!("eyJhbGciOiJub25lIn0.{encoded}.signature");
            serde_json::to_vec(&serde_json::json!({
                "tokens": {"access_token": jwt, "id_token": jwt}
            }))
            .expect("auth json")
        }

        let (token, account) =
            codex_credentials_from(&auth(Some(NOW + 3600)), NOW).expect("live credentials");
        assert!(!token.is_empty());
        assert_eq!(account, Some("acct-123".to_string()));

        assert_eq!(
            codex_credentials_from(&auth(Some(NOW - 1)), NOW),
            Err("codex credentials expired; run codex to log in".to_string())
        );
        // Spending a request right on the boundary buys nothing: 60 s of slack.
        assert_eq!(
            codex_credentials_from(&auth(Some(NOW + 30)), NOW),
            Err("codex credentials expired; run codex to log in".to_string())
        );
        // No `exp` counts as usable: never discard the only credential over a
        // field that was not written.
        assert!(codex_credentials_from(&auth(None), NOW).is_ok());
        assert!(codex_credentials_from(b"{}", NOW).is_err());
    }

    #[test]
    fn rejects_jwt_without_claim() {
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode("{}");
        assert_eq!(account_id(&format!("header.{encoded}.sig")), None);
        assert_eq!(account_id("not-a-jwt"), None);
    }
}
