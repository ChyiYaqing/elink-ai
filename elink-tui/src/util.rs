use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn expand_tilde(value: &str) -> PathBuf {
    if value == "~" {
        if let Some(home) = dirs::home_dir() {
            return home;
        }
    }
    if let Some(rest) = value.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(value)
}

pub fn epoch_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or(0)
}

/// 4868001 -> "4,868,001"
pub fn format_tokens(value: u64) -> String {
    let digits = value.to_string();
    let mut result = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            result.push(',');
        }
        result.push(character);
    }
    result
}

/// 87 -> "1h 27m", 4320 -> "3d 0h", 45 -> "45m"
pub fn format_minutes(minutes: i64) -> String {
    if minutes >= 48 * 60 {
        format!("{}d {}h", minutes / 1440, (minutes % 1440) / 60)
    } else if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{}m", minutes.max(0))
    }
}

/// 47 -> "47s", 130 -> "2m", 7300 -> "2h"
pub fn format_age(seconds: i64) -> String {
    if seconds < 0 {
        "0s".to_string()
    } else if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h", seconds / 3600)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_tokens_with_separators() {
        assert_eq!(format_tokens(0), "0");
        assert_eq!(format_tokens(999), "999");
        assert_eq!(format_tokens(61471), "61,471");
        assert_eq!(format_tokens(4_868_001), "4,868,001");
    }

    #[test]
    fn formats_minutes() {
        assert_eq!(format_minutes(45), "45m");
        assert_eq!(format_minutes(87), "1h 27m");
        assert_eq!(format_minutes(4320), "3d 0h");
        assert_eq!(format_minutes(8729), "6d 1h");
    }
}
