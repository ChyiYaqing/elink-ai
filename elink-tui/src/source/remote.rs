use std::io::Read;

use crate::model::Snapshot;

const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_MODELS_PER_PROVIDER: usize = 256;
const MAX_STATUS_BYTES: usize = 32;
const MAX_MODEL_NAME_BYTES: usize = 256;
const MAX_PROVIDER_ERROR_BYTES: usize = 4096;

pub fn fetch(agent: &ureq::Agent, base_url: &str) -> Result<Snapshot, String> {
    let url = format!("{}/v1/status", base_url.trim_end_matches('/'));
    let response = agent.get(&url).call().map_err(|error| match error {
        ureq::Error::Status(code, _) => format!("bridge HTTP {code}"),
        ureq::Error::Transport(transport) => format!("bridge unreachable: {transport}"),
    })?;
    decode(response.into_reader())
}

fn decode(reader: impl Read) -> Result<Snapshot, String> {
    let mut body = Vec::new();
    reader
        .take((MAX_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut body)
        .map_err(|error| format!("bridge response read failed: {error}"))?;
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(format!(
            "bridge response exceeds {MAX_RESPONSE_BYTES} bytes"
        ));
    }
    let snapshot: Snapshot = serde_json::from_slice(&body)
        .map_err(|error| format!("bridge response parse failed: {error}"))?;
    validate(&snapshot)?;
    Ok(snapshot)
}

fn validate(snapshot: &Snapshot) -> Result<(), String> {
    if snapshot.schema_version != 1 {
        return Err(format!(
            "unsupported bridge schema_version {}",
            snapshot.schema_version
        ));
    }
    for (name, provider) in [("claude", &snapshot.claude), ("codex", &snapshot.codex)] {
        if provider.status.len() > MAX_STATUS_BYTES {
            return Err(format!(
                "bridge {name} status exceeds {MAX_STATUS_BYTES} bytes"
            ));
        }
        if provider.model_usage_today.len() > MAX_MODELS_PER_PROVIDER {
            return Err(format!(
                "bridge {name} model_usage_today exceeds {MAX_MODELS_PER_PROVIDER} entries"
            ));
        }
        if provider
            .model_usage_today
            .iter()
            .any(|usage| usage.model.len() > MAX_MODEL_NAME_BYTES)
        {
            return Err(format!(
                "bridge {name} model name exceeds {MAX_MODEL_NAME_BYTES} bytes"
            ));
        }
        if provider
            .error
            .as_ref()
            .is_some_and(|error| error.len() > MAX_PROVIDER_ERROR_BYTES)
        {
            return Err(format!(
                "bridge {name} error exceeds {MAX_PROVIDER_ERROR_BYTES} bytes"
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use serde_json::json;

    use super::*;

    #[test]
    fn rejects_unsupported_schema_version() {
        let body = br#"{"schema_version":2,"claude":{},"codex":{}}"#;

        let error = decode(Cursor::new(body)).expect_err("schema v2 must be rejected");

        assert!(error.contains("unsupported bridge schema_version 2"));
    }

    #[test]
    fn rejects_response_over_size_limit() {
        let body = vec![b' '; MAX_RESPONSE_BYTES + 1];

        let error = decode(Cursor::new(body)).expect_err("large response must be rejected");

        assert!(error.contains("response exceeds"));
    }

    #[test]
    fn rejects_oversized_provider_collections_and_strings() {
        let models: Vec<_> = (0..=MAX_MODELS_PER_PROVIDER)
            .map(|index| json!({"model": format!("model-{index}"), "tokens": 1}))
            .collect();
        let body = serde_json::to_vec(&json!({
            "schema_version": 1,
            "claude": {"model_usage_today": models},
            "codex": {}
        }))
        .expect("serialize test response");
        assert!(decode(Cursor::new(body))
            .expect_err("large model collection must be rejected")
            .contains("model_usage_today exceeds"));

        let body = serde_json::to_vec(&json!({
            "schema_version": 1,
            "claude": {
                "model_usage_today": [{
                    "model": "x".repeat(MAX_MODEL_NAME_BYTES + 1),
                    "tokens": 1
                }]
            },
            "codex": {}
        }))
        .expect("serialize test response");
        assert!(decode(Cursor::new(body))
            .expect_err("long model name must be rejected")
            .contains("model name exceeds"));

        let body = serde_json::to_vec(&json!({
            "schema_version": 1,
            "claude": {"status": "x".repeat(MAX_STATUS_BYTES + 1)},
            "codex": {}
        }))
        .expect("serialize test response");
        assert!(decode(Cursor::new(body))
            .expect_err("long status must be rejected")
            .contains("status exceeds"));
    }
}
