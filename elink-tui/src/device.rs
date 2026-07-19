use std::io::Read;
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

const POLL_INTERVAL_ACTIVE: Duration = Duration::from_secs(3);
const POLL_INTERVAL_IDLE: Duration = Duration::from_secs(1);
const MAX_DEVICE_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_DEVICE_STRING_BYTES: usize = 2 * 1024;
const MAX_PREVIEW_BYTES: u64 = 2 * 1024 * 1024;
const MAX_PREVIEW_DIMENSION: u32 = 4_096;
const MAX_PREVIEW_PIXELS: u64 = 4 * 1024 * 1024;
const MAX_PREVIEW_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// Parsed `GET /v1/device` payload from the Pi agent (port 8766).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DeviceInfo {
    pub version: Option<String>,
    pub resolution: Option<(u32, u32)>,
    pub bridge_url: String,
    pub mode: String,
    pub stale: bool,
    pub last_fetch_age_s: Option<i64>,
    pub last_refresh_age_s: Option<i64>,
    pub last_refresh_kind: String,
    pub partial_count: Option<i64>,
    pub error: Option<String>,
}

/// Decoded grayscale preview frame (`GET /v1/preview.png`).
#[derive(Debug, Clone, PartialEq)]
pub struct Preview {
    pub width: u32,
    pub height: u32,
    pub luma: Vec<u8>,
}

#[derive(Default)]
pub struct DeviceState {
    pub info: Option<DeviceInfo>,
    pub preview: Option<Preview>,
    pub error: Option<String>,
    pub updated_at: Option<Instant>,
    pub last_action: Option<String>,
}

pub enum DeviceCommand {
    SetMode(&'static str),
    Refresh(&'static str),
    SetBridge(String),
}

/// Background client for the Pi agent: polls `/v1/device` and the preview
/// while the device page is open and executes control commands, so the UI
/// thread never blocks on the device network.
pub struct DeviceLink {
    state: Arc<Mutex<DeviceState>>,
    commands: Sender<DeviceCommand>,
    active: Arc<AtomicBool>,
}

impl DeviceLink {
    pub fn spawn(base_url: String) -> Self {
        let state: Arc<Mutex<DeviceState>> = Arc::default();
        let active = Arc::new(AtomicBool::new(false));
        let (commands, receiver) = mpsc::channel::<DeviceCommand>();
        let worker_state = Arc::clone(&state);
        let worker_active = Arc::clone(&active);
        thread::spawn(move || {
            let agent = ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(3))
                .build();
            let base = base_url.trim_end_matches('/').to_string();
            loop {
                let is_active = worker_active.load(Ordering::Relaxed);
                if is_active {
                    poll(&agent, &base, &worker_state);
                }
                let wait = if is_active {
                    POLL_INTERVAL_ACTIVE
                } else {
                    POLL_INTERVAL_IDLE
                };
                match receiver.recv_timeout(wait) {
                    Ok(command) => {
                        let outcome = execute(&agent, &base, &command);
                        lock(&worker_state).last_action = Some(outcome);
                        // Re-poll immediately so the page reflects the action.
                        if worker_active.load(Ordering::Relaxed) {
                            poll(&agent, &base, &worker_state);
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        });
        Self {
            state,
            commands,
            active,
        }
    }

    pub fn state(&self) -> MutexGuard<'_, DeviceState> {
        lock(&self.state)
    }

    pub fn set_active(&self, active: bool) {
        self.active.store(active, Ordering::Relaxed);
    }

    pub fn send(&self, command: DeviceCommand) {
        let _ = self.commands.send(command);
    }
}

fn lock(state: &Arc<Mutex<DeviceState>>) -> MutexGuard<'_, DeviceState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn poll(agent: &ureq::Agent, base: &str, state: &Arc<Mutex<DeviceState>>) {
    match fetch_info(agent, base) {
        Ok(info) => {
            let preview = fetch_preview(agent, base).ok();
            let mut state = lock(state);
            state.info = Some(info);
            if preview.is_some() {
                state.preview = preview;
            }
            state.error = None;
            state.updated_at = Some(Instant::now());
        }
        Err(error) => {
            lock(state).error = Some(error);
        }
    }
}

fn fetch_info(agent: &ureq::Agent, base: &str) -> Result<DeviceInfo, String> {
    let response = agent
        .get(&format!("{base}/v1/device"))
        .call()
        .map_err(|error| match error {
            ureq::Error::Status(code, _) => format!("device HTTP {code}"),
            ureq::Error::Transport(_) => "device unreachable".to_string(),
        })?;
    // `into_reader` exposes ureq's decompressed body, so the limit applies to
    // the bytes serde_json will actually parse rather than the wire size.
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take((MAX_DEVICE_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "device response read failed".to_string())?;
    if bytes.len() > MAX_DEVICE_RESPONSE_BYTES {
        return Err("device response too large".to_string());
    }
    let json: Value =
        serde_json::from_slice(&bytes).map_err(|_| "device response parse failed".to_string())?;
    parse_info(&json)
}

pub fn parse_info(json: &Value) -> Result<DeviceInfo, String> {
    if !strings_within_limit(json) {
        return Err("device response string too large".to_string());
    }
    if json.get("device_type").and_then(Value::as_str) != Some("elink-agent") {
        return Err("target is not an elink-agent".to_string());
    }
    let resolution = json.get("resolution").and_then(|value| {
        let list = value.as_array()?;
        Some((
            u32::try_from(list.first()?.as_i64()?).ok()?,
            u32::try_from(list.get(1)?.as_i64()?).ok()?,
        ))
    });
    Ok(DeviceInfo {
        version: json
            .get("version")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        resolution,
        bridge_url: json
            .get("bridge_url")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        mode: json
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("dashboard")
            .to_string(),
        stale: json.get("stale").and_then(Value::as_bool).unwrap_or(true),
        last_fetch_age_s: json.get("last_fetch_age_s").and_then(Value::as_i64),
        last_refresh_age_s: json.get("last_refresh_age_s").and_then(Value::as_i64),
        last_refresh_kind: json
            .get("last_refresh_kind")
            .and_then(Value::as_str)
            .unwrap_or("none")
            .to_string(),
        partial_count: json.get("partial_count").and_then(Value::as_i64),
        error: json
            .get("error")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
    })
}

fn strings_within_limit(value: &Value) -> bool {
    match value {
        Value::String(value) => value.len() <= MAX_DEVICE_STRING_BYTES,
        Value::Array(values) => values.iter().all(strings_within_limit),
        Value::Object(values) => values.iter().all(|(key, value)| {
            key.len() <= MAX_DEVICE_STRING_BYTES && strings_within_limit(value)
        }),
        _ => true,
    }
}

fn fetch_preview(agent: &ureq::Agent, base: &str) -> Result<Preview, String> {
    let response = agent
        .get(&format!("{base}/v1/preview.png"))
        .call()
        .map_err(|_| "no preview".to_string())?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_PREVIEW_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|_| "preview read failed".to_string())?;
    decode_preview(&bytes)
}

/// Decodes the agent's PNG (1-bit or grayscale in practice; any color type
/// is normalized) into 8-bit luminance.
pub fn decode_preview(bytes: &[u8]) -> Result<Preview, String> {
    let mut decoder = png::Decoder::new(bytes);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let limits = png::Limits {
        bytes: MAX_PREVIEW_OUTPUT_BYTES,
    };
    decoder.set_limits(limits);
    let mut reader = decoder
        .read_info()
        .map_err(|_| "preview decode failed".to_string())?;
    let (width, height) = reader.info().size();
    let pixels = u64::from(width) * u64::from(height);
    let output_buffer_size = reader.output_buffer_size();
    if width > MAX_PREVIEW_DIMENSION
        || height > MAX_PREVIEW_DIMENSION
        || pixels > MAX_PREVIEW_PIXELS
        || output_buffer_size > MAX_PREVIEW_OUTPUT_BYTES
    {
        return Err("preview too large".to_string());
    }
    let mut buffer = vec![0u8; output_buffer_size];
    let frame = reader
        .next_frame(&mut buffer)
        .map_err(|_| "preview decode failed".to_string())?;
    let pixels = &buffer[..frame.buffer_size()];
    let channels = match frame.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return Err("preview decode failed".to_string()),
    };
    let luma = pixels
        .chunks_exact(channels)
        .map(|pixel| {
            if channels >= 3 {
                ((u32::from(pixel[0]) + u32::from(pixel[1]) + u32::from(pixel[2])) / 3) as u8
            } else {
                pixel[0]
            }
        })
        .collect();
    Ok(Preview {
        width: frame.width,
        height: frame.height,
        luma,
    })
}

/// The URL a device should use to reach this machine's own `/v1/status`
/// listener: the local IP on the route toward the device plus the listener
/// port. Returns None when the listener is disabled or addresses are opaque.
pub fn local_bridge_url(device_url: &str, hook_listen: &str) -> Option<String> {
    let port = hook_listen.rsplit_once(':')?.1.parse::<u16>().ok()?;
    let host = device_url
        .trim_start_matches("http://")
        .trim_start_matches("https://")
        .split('/')
        .next()?;
    let target = if host.contains(':') {
        host.to_string()
    } else {
        format!("{host}:8766")
    };
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect(target).ok()?;
    let ip = socket.local_addr().ok()?.ip();
    Some(format!("http://{ip}:{port}"))
}

fn execute(agent: &ureq::Agent, base: &str, command: &DeviceCommand) -> String {
    let (result, label) = match command {
        DeviceCommand::SetMode(mode) => (
            agent
                .post(&format!("{base}/v1/display/mode"))
                .send_json(serde_json::json!({"mode": mode})),
            format!("mode → {mode}"),
        ),
        DeviceCommand::Refresh(kind) => (
            agent
                .post(&format!("{base}/v1/display/refresh"))
                .send_json(serde_json::json!({"kind": kind})),
            format!("{kind} refresh requested"),
        ),
        DeviceCommand::SetBridge(url) => (
            agent
                .request("PUT", &format!("{base}/v1/config/bridge"))
                .send_json(serde_json::json!({"bridge_url": url})),
            format!("bridge → {url}"),
        ),
    };
    match result {
        Ok(_) => label,
        Err(ureq::Error::Status(code, _)) => format!("{label} failed: HTTP {code}"),
        Err(ureq::Error::Transport(_)) => format!("{label} failed: device unreachable"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;
    use std::net::TcpListener;

    #[test]
    fn parses_device_info_payload() {
        let payload = json!({
            "schema_version": 1,
            "device_type": "elink-agent",
            "version": "0.1.12",
            "resolution": [648, 480],
            "bridge_url": "http://192.168.1.20:8765",
            "mode": "dashboard",
            "stale": false,
            "last_fetch_age_s": 2,
            "last_refresh_age_s": 31,
            "last_refresh_kind": "partial",
            "partial_count": 7,
            "error": null
        });

        let info = parse_info(&payload).expect("device info must parse");

        assert_eq!(info.version.as_deref(), Some("0.1.12"));
        assert_eq!(info.resolution, Some((648, 480)));
        assert_eq!(info.mode, "dashboard");
        assert!(!info.stale);
        assert_eq!(info.last_refresh_kind, "partial");
        assert_eq!(info.partial_count, Some(7));
        assert_eq!(info.error, None);
    }

    #[test]
    fn rejects_non_agent_devices() {
        assert!(parse_info(&json!({"device_type": "toaster"})).is_err());
        assert!(parse_info(&json!({})).is_err());
    }

    #[test]
    fn rejects_oversized_device_strings() {
        let payload = json!({
            "device_type": "elink-agent",
            "bridge_url": "x".repeat(2_049),
        });

        assert!(parse_info(&payload).is_err());
    }

    #[test]
    fn rejects_oversized_device_response_body() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let address = listener.local_addr().expect("server address");
        let body = json!({
            "device_type": "elink-agent",
            "padding": "x".repeat(64 * 1024),
        })
        .to_string();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .expect("send response");
        });
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(3))
            .build();

        let result = fetch_info(&agent, &format!("http://{address}"));
        server.join().expect("server thread");

        assert_eq!(result.unwrap_err(), "device response too large");
    }

    #[test]
    fn decodes_one_bit_png_previews() {
        // 2x2 PNG, 1-bit grayscale: top-left white, others black.
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 2, 2);
            encoder.set_color(png::ColorType::Grayscale);
            encoder.set_depth(png::BitDepth::One);
            let mut writer = encoder.write_header().expect("header");
            // Rows are bit-packed most-significant-bit first.
            writer
                .write_image_data(&[0b1000_0000, 0b0000_0000])
                .expect("image data");
        }

        let preview = decode_preview(&bytes).expect("must decode");

        assert_eq!((preview.width, preview.height), (2, 2));
        assert_eq!(preview.luma, vec![255, 0, 0, 0]);
    }

    #[test]
    fn decodes_device_sized_png_previews() {
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 648, 480);
            encoder.set_color(png::ColorType::Grayscale);
            encoder.set_depth(png::BitDepth::One);
            let mut writer = encoder.write_header().expect("header");
            writer
                .write_image_data(&vec![0; 81 * 480])
                .expect("image data");
        }

        let preview = decode_preview(&bytes).expect("device preview must decode");

        assert_eq!((preview.width, preview.height), (648, 480));
        assert_eq!(preview.luma.len(), 648 * 480);
    }

    #[test]
    fn rejects_png_previews_with_oversized_dimensions() {
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 4_097, 1);
            encoder.set_color(png::ColorType::Grayscale);
            encoder.set_depth(png::BitDepth::One);
            let mut writer = encoder.write_header().expect("header");
            writer.write_image_data(&vec![0; 513]).expect("image data");
        }

        assert_eq!(decode_preview(&bytes).unwrap_err(), "preview too large");
    }

    #[test]
    fn local_bridge_url_requires_listener_port() {
        assert_eq!(local_bridge_url("http://127.0.0.1:18766", ""), None);
        let url = local_bridge_url("http://127.0.0.1:18766", "0.0.0.0:8765")
            .expect("loopback route resolves");
        assert_eq!(url, "http://127.0.0.1:8765");
    }
}
