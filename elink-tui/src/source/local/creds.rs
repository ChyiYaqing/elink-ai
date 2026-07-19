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
    let json: serde_json::Value = serde_json::from_slice(&data)
        .map_err(|_| "codex credentials invalid; run codex to log in".to_string())?;
    let tokens = &json["tokens"];
    let token = match tokens["access_token"].as_str() {
        Some(value) if !value.is_empty() => value.to_string(),
        _ => return Err("codex credentials invalid; run codex to log in".to_string()),
    };
    let account = tokens["account_id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| tokens["id_token"].as_str().and_then(account_id));
    Ok((token, account))
}

/// Decodes the JWT payload (base64url, no signature check) and reads
/// `https://api.openai.com/auth.chatgpt_account_id`.
pub fn account_id(jwt: &str) -> Option<String> {
    let payload = jwt.split('.').nth(1)?;
    let mut value = payload.replace('-', "+").replace('_', "/");
    while value.len() % 4 != 0 {
        value.push('=');
    }
    let data = base64::engine::general_purpose::STANDARD
        .decode(value)
        .ok()?;
    let json: serde_json::Value = serde_json::from_slice(&data).ok()?;
    json["https://api.openai.com/auth"]["chatgpt_account_id"]
        .as_str()
        .map(str::to_string)
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

    #[test]
    fn rejects_jwt_without_claim() {
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode("{}");
        assert_eq!(account_id(&format!("header.{encoded}.sig")), None);
        assert_eq!(account_id("not-a-jwt"), None);
    }
}
