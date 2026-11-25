//! Converting token usage into an API-equivalent cost.
//!
//! This is **not** a bill: day-to-day usage runs on a Claude / ChatGPT
//! subscription, which does not charge per token inside the plan allowance. The
//! number answers "what would this same usage cost at list API prices", and the
//! UI must be worded that way rather than presenting it as money already spent.
//!
//! Unknown models yield no price rather than zero. Silently counting them as 0
//! keeps the total looking plausible while quietly under-reporting it, which is
//! much harder to notice than a missing number.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use serde_json::Value;

/// Per-million-token prices in USD for one model.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPricing {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

impl ModelPricing {
    /// Codex reasoning tokens are billed at the output rate.
    pub fn rate(&self, category: &str) -> Option<f64> {
        match category {
            "input" => Some(self.input),
            "output" | "reasoning" => Some(self.output),
            "cache_read" => Some(self.cache_read),
            "cache_write" => Some(self.cache_write),
            _ => None,
        }
    }
}

/// Published list prices, checked 2026-07-31.
///
/// Anthropic does not publish cache rates separately, so they follow its stated
/// rules: cache read is 0.1x input, cache write 1.25x input (the 5-minute TTL —
/// logs cannot tell the two TTLs apart, so take the common one). OpenAI numbers
/// are published per line and used as-is.
///
/// claude-sonnet-5 carries the standard 3/15 rather than its promotional 2/10,
/// which expires 2026-08-31. Keeping the standard rate means it becomes correct
/// on its own once the promo lapses; until then it slightly overstates. Override
/// via pricing.json to bill at the promo rate.
pub fn built_in() -> HashMap<String, ModelPricing> {
    [
        (
            "claude-fable-5",
            ModelPricing {
                input: 10.0,
                output: 50.0,
                cache_read: 1.0,
                cache_write: 12.5,
            },
        ),
        (
            "claude-opus-5",
            ModelPricing {
                input: 5.0,
                output: 25.0,
                cache_read: 0.5,
                cache_write: 6.25,
            },
        ),
        (
            "claude-opus-4-8",
            ModelPricing {
                input: 5.0,
                output: 25.0,
                cache_read: 0.5,
                cache_write: 6.25,
            },
        ),
        (
            "claude-sonnet-5",
            ModelPricing {
                input: 3.0,
                output: 15.0,
                cache_read: 0.3,
                cache_write: 3.75,
            },
        ),
        (
            "gpt-5.6-sol",
            ModelPricing {
                input: 5.0,
                output: 30.0,
                cache_read: 0.5,
                cache_write: 6.25,
            },
        ),
        (
            "gemini-2.5-pro",
            ModelPricing {
                input: 1.25,
                output: 10.0,
                cache_read: 0.125,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-2.5-flash",
            ModelPricing {
                input: 0.30,
                output: 2.50,
                cache_read: 0.03,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-2.5-flash-lite",
            ModelPricing {
                input: 0.10,
                output: 0.40,
                cache_read: 0.01,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-3-pro-preview",
            ModelPricing {
                input: 2.0,
                output: 12.0,
                cache_read: 0.2,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-3-flash-preview",
            ModelPricing {
                input: 0.5,
                output: 3.0,
                cache_read: 0.05,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-3.5-flash",
            ModelPricing {
                input: 1.50,
                output: 9.0,
                cache_read: 0.15,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-3.5-flash-lite",
            ModelPricing {
                input: 0.10,
                output: 0.40,
                cache_read: 0.01,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-3.8-flash",
            ModelPricing {
                input: 0.75,
                output: 3.75,
                cache_read: 0.0375,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-4-neon",
            ModelPricing {
                input: 3.0,
                output: 15.0,
                cache_read: 0.15,
                cache_write: 0.0,
            },
        ),
        (
            "gemini-4-argon",
            ModelPricing {
                input: 2.0,
                output: 10.0,
                cache_read: 0.10,
                cache_write: 0.0,
            },
        ),
    ]
    .into_iter()
    .map(|(model, pricing)| (model.to_string(), pricing))
    .collect()
}

/// Built-in table with user overrides applied. Prices change and new models
/// appear faster than releases ship, so the table has to be patchable.
pub fn table(override_path: &Path) -> HashMap<String, ModelPricing> {
    let mut table = built_in();
    table.extend(load_overrides(override_path));
    table
}

/// Override file format:
/// `{"model-name": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}}`
/// Missing fields count as 0; a broken file is ignored entirely, because falling
/// back to built-in prices beats refusing to render the usage screen.
pub fn load_overrides(path: &Path) -> HashMap<String, ModelPricing> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&text) else {
        return HashMap::new();
    };
    object
        .into_iter()
        .filter_map(|(model, value)| {
            let fields = value.as_object()?;
            let rate = |key: &str| {
                fields
                    .get(key)
                    .and_then(Value::as_f64)
                    .filter(|value| *value >= 0.0)
                    .unwrap_or(0.0)
            };
            Some((
                model,
                ModelPricing {
                    input: rate("input"),
                    output: rate("output"),
                    cache_read: rate("cache_read"),
                    cache_write: rate("cache_write"),
                },
            ))
        })
        .collect()
}

/// Cost of one model's category breakdown, in USD. `None` when unpriced.
pub fn cost(
    model: &str,
    categories: &BTreeMap<String, u64>,
    table: &HashMap<String, ModelPricing>,
) -> Option<f64> {
    let pricing = table.get(model)?;
    Some(
        categories
            .iter()
            .filter_map(|(category, tokens)| {
                Some(*tokens as f64 / 1_000_000.0 * pricing.rate(category)?)
            })
            .sum(),
    )
}

/// Total cost across a model -> category map, plus the models that had no price
/// and were therefore left out. Callers must surface `unpriced`, or a partial
/// total gets read as the whole.
#[derive(Debug, Default, PartialEq)]
pub struct CostTotal {
    pub cost: f64,
    pub unpriced: HashSet<String>,
}

pub fn total(
    usage: &HashMap<String, HashMap<String, u64>>,
    table: &HashMap<String, ModelPricing>,
) -> CostTotal {
    let mut result = CostTotal::default();
    for (model, categories) in usage {
        let Some(pricing) = table.get(model) else {
            result.unpriced.insert(model.clone());
            continue;
        };
        for (category, tokens) in categories {
            if let Some(rate) = pricing.rate(category) {
                result.cost += *tokens as f64 / 1_000_000.0 * rate;
            }
        }
    }
    result
}

/// Small amounts keep cents; past $100 the cents stop carrying information.
pub fn format_cost(cost: f64) -> String {
    format_money(cost, "USD")
}

/// One figure rendered in its own unit. `unit` is either an ISO currency code
/// or `credits`.
///
/// Money: cents matter for small amounts and stop mattering past 100.
/// Hard-coding `$` would render a euro-denominated cap as dollars, so unknown
/// codes are spelled out. Credits are not money and carry no symbol at all;
/// whole numbers print without a decimal point, because `1000.00 credits`
/// invites the reader to wonder whether it is currency after all.
pub fn format_money(value: f64, unit: &str) -> String {
    if unit == crate::source::local::quota::CREDITS_UNIT {
        let rounded = (value * 100.0).round() / 100.0;
        return if rounded.fract() == 0.0 {
            format!("{rounded:.0}")
        } else {
            format!("{rounded}")
        };
    }
    let amount = if value.abs() >= 100.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.2}")
    };
    match unit {
        "EUR" => format!("\u{20ac}{amount}"),
        "GBP" => format!("\u{a3}{amount}"),
        "JPY" | "CNY" => format!("\u{a5}{amount}"),
        "USD" => format!("${amount}"),
        other => format!("{amount} {other}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Credits are not money: no symbol, and whole numbers print without a
    /// decimal point so nobody reads them as currency.
    #[test]
    fn credits_render_without_a_currency_symbol() {
        assert_eq!(format_money(1000.0, "credits"), "1000");
        assert_eq!(format_money(12.5, "credits"), "12.5");
        assert_eq!(format_money(0.0, "credits"), "0");
        assert_eq!(format_money(10.3, "USD"), "$10.30");
        assert_eq!(format_money(2000.0, "USD"), "$2000");
        assert_eq!(format_money(10.3, "SEK"), "10.30 SEK");
    }

    fn categories(pairs: &[(&str, u64)]) -> BTreeMap<String, u64> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_string(), *value))
            .collect()
    }

    /// Published rates. Changing the built-in table must break this test —
    /// it is the only place a wrong price gets caught.
    #[test]
    fn built_in_rates_match_published_pricing() {
        let table = built_in();
        assert_eq!(table["claude-fable-5"].input, 10.0);
        assert_eq!(table["claude-fable-5"].output, 50.0);
        assert_eq!(table["claude-opus-5"].input, 5.0);
        assert_eq!(table["claude-opus-5"].cache_write, 6.25);
        assert_eq!(table["claude-sonnet-5"].output, 15.0);
        assert_eq!(table["gpt-5.6-sol"].output, 30.0);
    }

    #[test]
    fn reasoning_is_billed_as_output() {
        let sol = built_in()["gpt-5.6-sol"];
        assert_eq!(sol.rate("reasoning"), Some(sol.output));
        assert_eq!(sol.rate("nonsense"), None);
    }

    #[test]
    fn cost_sums_categories_at_their_own_rates() {
        // 1M input + 1M output + 1M cache_read = 5 + 25 + 0.5
        let value = cost(
            "claude-opus-5",
            &categories(&[
                ("input", 1_000_000),
                ("output", 1_000_000),
                ("cache_read", 1_000_000),
            ]),
            &built_in(),
        );
        assert!((value.unwrap() - 30.5).abs() < 1e-9);
    }

    /// Unknown models yield None, never a silent zero.
    #[test]
    fn unknown_model_has_no_price_rather_than_zero() {
        assert_eq!(
            cost(
                "codex-auto-review",
                &categories(&[("input", 1_000_000)]),
                &built_in()
            ),
            None
        );
    }

    #[test]
    fn total_reports_unpriced_models() {
        let mut usage: HashMap<String, HashMap<String, u64>> = HashMap::new();
        usage.insert(
            "claude-opus-5".into(),
            [("input".to_string(), 1_000_000u64)].into_iter().collect(),
        );
        usage.insert(
            "codex-auto-review".into(),
            [("input".to_string(), 9_000_000u64)].into_iter().collect(),
        );
        let result = total(&usage, &built_in());
        assert!((result.cost - 5.0).abs() < 1e-9);
        assert_eq!(
            result.unpriced,
            ["codex-auto-review".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn override_replaces_and_extends_the_built_in_table() {
        let dir = std::env::temp_dir().join(format!("elink-pricing-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pricing.json");
        std::fs::write(
            &path,
            r#"{"claude-sonnet-5": {"input": 2, "output": 10},
                "gpt-5.6-terra": {"input": 2, "output": 12}}"#,
        )
        .unwrap();

        let table = table(&path);
        assert_eq!(table["claude-sonnet-5"].input, 2.0);
        // a model the built-in table never knew about
        assert_eq!(table["gpt-5.6-terra"].output, 12.0);
        // untouched entries keep the built-in rate
        assert_eq!(table["claude-opus-5"].input, 5.0);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A broken override must not take the usage screen down with it.
    #[test]
    fn broken_override_falls_back_to_built_in() {
        let dir = std::env::temp_dir().join(format!("elink-pricing-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pricing.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert_eq!(table(&path)["claude-opus-5"].input, 5.0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_override_is_not_an_error() {
        assert!(load_overrides(Path::new("/nonexistent/pricing.json")).is_empty());
    }

    #[test]
    fn format_keeps_cents_only_when_they_matter() {
        assert_eq!(format_cost(0.42), "$0.42");
        assert_eq!(format_cost(53.5), "$53.50");
        assert_eq!(format_cost(1234.56), "$1235");
    }
}
