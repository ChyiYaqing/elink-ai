use serde::{Deserialize, Serialize, Serializer};

/// Parsed form of one `/v1/status` provider object. The bridge names the
/// quota fields per provider (claude: `five_hour_*`/`seven_day_*`, codex:
/// `primary_*`/`weekly_*`); serde aliases normalize both spellings into the
/// codex-style names. Unknown percentages and reset times are JSON `null`,
/// never zero (docs/protocol.md).
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(default)]
pub struct ProviderStatus {
    pub status: String,
    pub tokens_today: u64,
    pub model_usage_today: Vec<ModelUsage>,
    #[serde(alias = "five_hour_pct")]
    pub primary_pct: Option<f64>,
    #[serde(alias = "five_hour_reset_min")]
    pub primary_reset_min: Option<i64>,
    #[serde(alias = "seven_day_pct")]
    pub weekly_pct: Option<f64>,
    #[serde(alias = "seven_day_reset_min")]
    pub weekly_reset_min: Option<i64>,
    pub needs_input: bool,
    pub error: Option<String>,
    pub provider_usage_fetched_at: Option<i64>,
    pub provider_usage_cached: bool,
    /// Today's usage priced at list API rates. This is not a bill — the usage
    /// runs on a subscription — so the UI must label it as a conversion.
    /// `None` when nothing could be priced at all.
    /// `serde(default)` keeps payloads from older nodes parseable.
    #[serde(default)]
    pub cost_today: Option<f64>,
    /// Models left out of `cost_today` for lack of a published price. Shown so
    /// a partial total is never mistaken for the whole.
    #[serde(default)]
    pub unpriced_models: Vec<String>,
    /// Weekly limits scoped to a single model (Claude only). Empty on bridges
    /// that predate the field, which reads the same as "no scoped limits".
    #[serde(default)]
    pub scoped_limits: Vec<ScopedLimitStatus>,
    /// Pay-as-you-go pool on top of the subscription. `None` means the account
    /// has no such pool — distinct from a pool that is merely unused.
    #[serde(default)]
    pub extra_usage: Option<ExtraUsageStatus>,
    /// Credits still on the account (Codex). `None` when the account has no
    /// credit pool at all, which is not the same as a balance of zero.
    #[serde(default)]
    pub credit_balance: Option<f64>,
}

/// One model-scoped weekly limit as it crosses the bridge.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ScopedLimitStatus {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub pct: Option<f64>,
    #[serde(default)]
    pub reset_min: Option<i64>,
}

/// Extra-usage pool as it crosses the bridge. Amounts are converted already;
/// the producer does the minor-unit shift so every reader agrees.
///
/// `unit` is either an ISO currency code or `credits` — Codex counts its limit
/// in credits, so the unit has to travel with the numbers.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ExtraUsageStatus {
    #[serde(default)]
    pub used: f64,
    #[serde(default)]
    pub limit: f64,
    #[serde(default)]
    pub pct: f64,
    #[serde(default = "default_unit", alias = "currency")]
    pub unit: String,
}

fn default_unit() -> String {
    "USD".to_string()
}

impl Default for ProviderStatus {
    fn default() -> Self {
        Self {
            status: "offline".to_string(),
            tokens_today: 0,
            model_usage_today: Vec::new(),
            primary_pct: None,
            primary_reset_min: None,
            weekly_pct: None,
            weekly_reset_min: None,
            needs_input: false,
            error: None,
            provider_usage_fetched_at: None,
            provider_usage_cached: false,
            cost_today: None,
            unpriced_models: Vec::new(),
            scoped_limits: Vec::new(),
            extra_usage: None,
            credit_balance: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ModelUsage {
    pub model: String,
    #[serde(default)]
    pub tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Cluster {
    pub enabled: bool,
    pub node_count: u32,
    pub online_count: u32,
    pub last_synced_at: Option<i64>,
}

impl Default for Cluster {
    fn default() -> Self {
        Self {
            enabled: false,
            node_count: 1,
            online_count: 1,
            last_synced_at: None,
        }
    }
}

/// Full `/v1/status` snapshot. The version and two provider objects are
/// required; additive fields such as `cluster` and `provider_usage_*` remain
/// optional for compatibility with older bridges and fixtures.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Snapshot {
    pub schema_version: u32,
    pub generated_at: Option<i64>,
    pub usage_fetched_at: Option<i64>,
    pub cluster: Option<Cluster>,
    pub claude: ProviderStatus,
    pub codex: ProviderStatus,
}

#[derive(Serialize)]
struct ProviderWire<'a> {
    status: &'a str,
    tokens_today: u64,
    model_usage_today: &'a [ModelUsage],
    needs_input: bool,
    error: &'a Option<String>,
    provider_usage_fetched_at: Option<i64>,
    provider_usage_cached: bool,
    cost_today: Option<f64>,
    unpriced_models: &'a [String],
    scoped_limits: &'a [ScopedLimitStatus],
    extra_usage: &'a Option<ExtraUsageStatus>,
    credit_balance: Option<f64>,
}

impl<'a> From<&'a ProviderStatus> for ProviderWire<'a> {
    fn from(value: &'a ProviderStatus) -> Self {
        Self {
            status: &value.status,
            tokens_today: value.tokens_today,
            model_usage_today: &value.model_usage_today,
            needs_input: value.needs_input,
            error: &value.error,
            provider_usage_fetched_at: value.provider_usage_fetched_at,
            provider_usage_cached: value.provider_usage_cached,
            cost_today: value.cost_today,
            unpriced_models: &value.unpriced_models,
            scoped_limits: &value.scoped_limits,
            extra_usage: &value.extra_usage,
            credit_balance: value.credit_balance,
        }
    }
}

#[derive(Serialize)]
struct ClaudeProviderWire<'a> {
    #[serde(flatten)]
    provider: ProviderWire<'a>,
    five_hour_pct: Option<f64>,
    five_hour_reset_min: Option<i64>,
    seven_day_pct: Option<f64>,
    seven_day_reset_min: Option<i64>,
}

#[derive(Serialize)]
struct CodexProviderWire<'a> {
    #[serde(flatten)]
    provider: ProviderWire<'a>,
    primary_pct: Option<f64>,
    primary_reset_min: Option<i64>,
    weekly_pct: Option<f64>,
    weekly_reset_min: Option<i64>,
}

impl Serialize for Snapshot {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        #[derive(Serialize)]
        struct SnapshotWire<'a> {
            schema_version: u32,
            generated_at: Option<i64>,
            usage_fetched_at: Option<i64>,
            cluster: &'a Option<Cluster>,
            claude: ClaudeProviderWire<'a>,
            codex: CodexProviderWire<'a>,
        }

        SnapshotWire {
            schema_version: self.schema_version,
            generated_at: self.generated_at,
            usage_fetched_at: self.usage_fetched_at,
            cluster: &self.cluster,
            claude: ClaudeProviderWire {
                provider: (&self.claude).into(),
                five_hour_pct: self.claude.primary_pct,
                five_hour_reset_min: self.claude.primary_reset_min,
                seven_day_pct: self.claude.weekly_pct,
                seven_day_reset_min: self.claude.weekly_reset_min,
            },
            codex: CodexProviderWire {
                provider: (&self.codex).into(),
                primary_pct: self.codex.primary_pct,
                primary_reset_min: self.codex.primary_reset_min,
                weekly_pct: self.codex.weekly_pct,
                weekly_reset_min: self.codex.weekly_reset_min,
            },
        }
        .serialize(serializer)
    }
}
