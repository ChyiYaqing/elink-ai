use elink_tui::model::Snapshot;

const FIXTURE: &str = include_str!("../../fixtures/status-v1.json");

#[test]
fn deserializes_repo_fixture() {
    let snapshot: Snapshot = serde_json::from_str(FIXTURE).expect("fixture must parse");
    assert_eq!(snapshot.schema_version, 1);
    assert_eq!(snapshot.generated_at, Some(1_783_933_200));
    assert_eq!(snapshot.usage_fetched_at, Some(1_783_933_140));
    // The fixture predates the cluster field; it must default cleanly.
    assert_eq!(snapshot.cluster, None);

    let claude = &snapshot.claude;
    assert_eq!(claude.status, "working");
    assert_eq!(claude.tokens_today, 4_868_001);
    assert_eq!(claude.model_usage_today.len(), 2);
    assert_eq!(claude.model_usage_today[0].model, "claude-sonnet-4-5");
    assert_eq!(claude.model_usage_today[0].tokens, 3_211_000);
    assert_eq!(claude.primary_pct, Some(43.0));
    assert_eq!(claude.primary_reset_min, Some(87));
    assert_eq!(claude.weekly_pct, Some(68.0));
    assert_eq!(claude.weekly_reset_min, Some(4320));
    assert!(!claude.needs_input);
    assert_eq!(claude.error, None);
    assert_eq!(claude.provider_usage_fetched_at, None);
    assert!(!claude.provider_usage_cached);

    let codex = &snapshot.codex;
    assert_eq!(codex.status, "idle");
    assert_eq!(codex.tokens_today, 61_471);
    assert_eq!(codex.primary_pct, Some(12.0));
    assert_eq!(codex.primary_reset_min, Some(144));
    assert_eq!(codex.weekly_pct, Some(22.0));
    assert_eq!(codex.weekly_reset_min, Some(8729));
    assert!(codex.needs_input);
}

#[test]
fn deserializes_full_live_shape() {
    let text = r#"{
        "schema_version": 1,
        "generated_at": 1783933200,
        "usage_fetched_at": null,
        "cluster": {"enabled": true, "node_count": 3, "online_count": 2, "last_synced_at": 1783933100},
        "claude": {
            "status": "offline",
            "tokens_today": 0,
            "model_usage_today": [],
            "five_hour_pct": null,
            "five_hour_reset_min": null,
            "seven_day_pct": null,
            "seven_day_reset_min": null,
            "needs_input": false,
            "error": "claude usage HTTP 500",
            "provider_usage_fetched_at": 1783933000,
            "provider_usage_cached": true
        },
        "codex": {
            "status": "idle",
            "tokens_today": 5,
            "model_usage_today": [{"model": "gpt-5.6-terra", "tokens": 5}],
            "primary_pct": 1.5,
            "primary_reset_min": 10,
            "weekly_pct": null,
            "weekly_reset_min": null,
            "needs_input": false,
            "error": null,
            "provider_usage_fetched_at": null,
            "provider_usage_cached": false
        }
    }"#;
    let snapshot: Snapshot = serde_json::from_str(text).expect("full shape must parse");
    let cluster = snapshot.cluster.expect("cluster present");
    assert!(cluster.enabled);
    assert_eq!(cluster.node_count, 3);
    assert_eq!(cluster.last_synced_at, Some(1_783_933_100));
    // Unknown quota stays None, never 0.
    assert_eq!(snapshot.claude.primary_pct, None);
    assert_eq!(
        snapshot.claude.error.as_deref(),
        Some("claude usage HTTP 500")
    );
    assert!(snapshot.claude.provider_usage_cached);
    assert_eq!(snapshot.codex.primary_pct, Some(1.5));
    assert_eq!(snapshot.codex.weekly_pct, None);
}

#[test]
fn rejects_missing_required_snapshot_fields() {
    assert!(serde_json::from_str::<Snapshot>("{}").is_err());
    assert!(serde_json::from_str::<Snapshot>(r#"{"schema_version":1,"claude":{}}"#).is_err());
}

#[test]
fn serializes_provider_specific_quota_fields() {
    let snapshot: Snapshot = serde_json::from_str(FIXTURE).expect("fixture must parse");
    let value = serde_json::to_value(snapshot).expect("snapshot must serialize");

    let claude = value["claude"].as_object().expect("claude object");
    assert_eq!(claude["five_hour_pct"], 43.0);
    assert_eq!(claude["seven_day_pct"], 68.0);
    assert!(!claude.contains_key("primary_pct"));
    assert!(!claude.contains_key("weekly_pct"));

    let codex = value["codex"].as_object().expect("codex object");
    assert_eq!(codex["primary_pct"], 12.0);
    assert_eq!(codex["weekly_pct"], 22.0);
    assert!(!codex.contains_key("five_hour_pct"));
    assert!(!codex.contains_key("seven_day_pct"));
}
