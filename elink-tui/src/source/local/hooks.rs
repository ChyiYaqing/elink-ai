use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::cluster::{ClusterHttpRequest, ClusterService};
use crate::model::ProviderStatus;

const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_CONCURRENT_REQUESTS: usize = 32;
const REQUEST_DEADLINE: Duration = Duration::from_secs(5);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const WORKING_EVENTS: [&str; 8] = [
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "WorktreeCreate",
];
const IDLE_EVENTS: [&str; 3] = ["Stop", "SessionEnd", "SessionStart"];

#[derive(Default)]
struct State {
    /// agent -> ("working"|"idle", epoch of the event)
    hooks: HashMap<String, (&'static str, i64)>,
    /// agent -> epoch when attention was requested
    needs_input: HashMap<String, i64>,
}

/// Port of StatusService.recordEvent/overlay: CLI hook events refine the
/// mtime-derived state and drive `needs_input`, which file scanning alone
/// cannot see.
#[derive(Default)]
pub struct HookRegistry {
    state: Mutex<State>,
}

impl HookRegistry {
    pub fn record(&self, agent: &str, event: &str, message: Option<&str>, now: i64) {
        if agent != "claude" && agent != "codex" && agent != "gemini" {
            return;
        }
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if ["PermissionRequest", "Elicitation"].contains(&event)
            || (event == "Notification" && is_permission(message))
        {
            state.needs_input.insert(agent.to_string(), now);
            return;
        }
        if WORKING_EVENTS.contains(&event) {
            state.hooks.insert(agent.to_string(), ("working", now));
        } else if IDLE_EVENTS.contains(&event) {
            state.hooks.insert(agent.to_string(), ("idle", now));
        } else {
            return;
        }
        state.needs_input.remove(agent);
    }

    /// Working hooks override for 10 minutes; a fresh idle hook (< 60 s)
    /// downgrades a working state; attention lasts 5 minutes.
    pub fn apply(&self, agent: &str, status: &mut ProviderStatus, now: i64) {
        let Ok(state) = self.state.lock() else {
            return;
        };
        if let Some((hook_state, at)) = state.hooks.get(agent) {
            let age = now - at;
            if *hook_state == "working" && age < 600 {
                status.status = "working".to_string();
            }
            if *hook_state == "idle" && age < 60 && status.status == "working" {
                status.status = "idle".to_string();
            }
        }
        status.needs_input = state
            .needs_input
            .get(agent)
            .is_some_and(|at| now - at < 300);
    }
}

fn is_permission(message: Option<&str>) -> bool {
    let Some(text) = message else {
        return false;
    };
    let text = text.to_lowercase();
    text.contains("permission") || text.contains("approve") || text.contains("approval")
}

/// Latest local snapshot pre-serialized in bridge wire format; `None` until
/// the first local collect completes.
pub type SharedStatus = Arc<Mutex<Option<String>>>;

struct ConnectionGuard {
    active: Arc<AtomicUsize>,
}

impl ConnectionGuard {
    fn acquire(active: &Arc<AtomicUsize>) -> Option<Self> {
        active
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
                (current < MAX_CONCURRENT_REQUESTS).then_some(current + 1)
            })
            .ok()?;
        Some(Self {
            active: Arc::clone(active),
        })
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::Relaxed);
    }
}

pub struct ListenerHandle {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
    #[cfg(test)]
    active: Arc<AtomicUsize>,
}

impl ListenerHandle {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for ListenerHandle {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// Accepts the same `POST /v1/event` requests as the mac-app bridge so the
/// existing `hooks/` scripts work unchanged on Linux, and serves the latest
/// local snapshot on `GET /v1/status` so the Pi agent (or another node) can
/// use this machine as a bridge. The returned handle owns the listener;
/// dropping it stops and joins the accept thread. Callers treat a bind failure
/// (e.g. the port is taken) as non-fatal because the mtime fallback still
/// works.
pub fn spawn_listener(
    address: &str,
    registry: Arc<HookRegistry>,
    status: SharedStatus,
    cluster: Arc<ClusterService>,
) -> std::io::Result<ListenerHandle> {
    let listener = TcpListener::bind(address)?;
    let local = listener.local_addr()?;
    listener.set_nonblocking(true)?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let worker_shutdown = Arc::clone(&shutdown);
    let active = Arc::new(AtomicUsize::new(0));
    let worker_active = Arc::clone(&active);
    let worker = thread::spawn(move || {
        while !worker_shutdown.load(Ordering::Acquire) {
            match listener.accept() {
                Ok((stream, peer)) => {
                    if stream.set_nonblocking(false).is_err() {
                        continue;
                    }
                    let Some(guard) = ConnectionGuard::acquire(&worker_active) else {
                        continue;
                    };
                    let registry = Arc::clone(&registry);
                    let status = Arc::clone(&status);
                    let cluster = Arc::clone(&cluster);
                    thread::spawn(move || {
                        let _guard = guard;
                        let _ = handle(stream, &registry, &status, &cluster, peer, local.port());
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(ACCEPT_POLL_INTERVAL);
                }
                Err(_) => break,
            }
        }
    });
    Ok(ListenerHandle {
        local_addr: local,
        shutdown,
        worker: Some(worker),
        #[cfg(test)]
        active,
    })
}

fn handle(
    mut stream: TcpStream,
    registry: &HookRegistry,
    status: &SharedStatus,
    cluster: &ClusterService,
    peer: SocketAddr,
    local_port: u16,
) -> std::io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let request = read_request(&mut stream, Instant::now() + REQUEST_DEADLINE)?;
    let response: (u16, &str, Vec<u8>) = match request {
        Some(request) if request.method == "POST" && request.path == "/v1/event" => {
            match serde_json::from_slice::<Value>(&request.body) {
                Ok(event) => {
                    registry.record(
                        event.get("agent").and_then(Value::as_str).unwrap_or(""),
                        event.get("event").and_then(Value::as_str).unwrap_or(""),
                        event.get("message").and_then(Value::as_str),
                        crate::util::epoch_now(),
                    );
                    (200, "OK", br#"{"ok":true}"#.to_vec())
                }
                Err(_) => (400, "Bad Request", br#"{"ok":false}"#.to_vec()),
            }
        }
        Some(request)
            if request.method == "GET" && (request.path == "/v1/status" || request.path == "/") =>
        {
            let latest = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone();
            match latest {
                Some(body) => (200, "OK", body.into_bytes()),
                None => (
                    503,
                    "Service Unavailable",
                    br#"{"ok":false,"error":"no local snapshot yet"}"#.to_vec(),
                ),
            }
        }
        Some(request) if request.method == "GET" && request.path == "/v1/health" => {
            (200, "OK", br#"{"ok":true,"schema_version":1}"#.to_vec())
        }
        Some(request)
            if request.path.starts_with("/v2/cluster/")
                || request.path.starts_with("/v3/cluster/") =>
        {
            let response = cluster.handle_http(ClusterHttpRequest {
                method: request.method,
                path: request.path,
                headers: request.headers,
                body: request.body,
                peer_host: peer.ip().to_string(),
                local_port,
            });
            (response.status, response.reason, response.body)
        }
        Some(_) => (404, "Not Found", br#"{"ok":false}"#.to_vec()),
        None => (400, "Bad Request", br#"{"ok":false}"#.to_vec()),
    };
    write!(
        stream,
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.0,
        response.1,
        response.2.len()
    )?;
    stream.write_all(&response.2)
}

struct ParsedRequest {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

/// Minimal HTTP/1.1 parse: request line, Content-Length, body. Anything
/// malformed or oversized returns None.
fn read_request(
    stream: &mut TcpStream,
    deadline: Instant,
) -> std::io::Result<Option<ParsedRequest>> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(position) = find_header_end(&buffer) {
            break position;
        }
        if buffer.len() > MAX_REQUEST_BYTES {
            return Ok(None);
        }
        let read = read_before_deadline(stream, &mut chunk, deadline)?;
        if read == 0 {
            return Ok(None);
        }
        buffer.extend_from_slice(&chunk[..read]);
    };
    let headers = String::from_utf8_lossy(&buffer[..header_end]).to_string();
    let mut lines = headers.lines();
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let (Some(method), Some(path)) = (parts.next(), parts.next()) else {
        return Ok(None);
    };
    let headers: HashMap<String, String> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string()))
        .collect();
    let content_length = headers
        .get("content-length")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    if content_length > MAX_REQUEST_BYTES {
        return Ok(None);
    }
    let mut body = buffer[header_end + 4..].to_vec();
    while body.len() < content_length {
        let read = read_before_deadline(stream, &mut chunk, deadline)?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..read]);
    }
    body.truncate(content_length);
    Ok(Some(ParsedRequest {
        method: method.to_string(),
        path: path.to_string(),
        headers,
        body,
    }))
}

fn read_before_deadline(
    stream: &mut TcpStream,
    buffer: &mut [u8],
    deadline: Instant,
) -> std::io::Result<usize> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::TimedOut, "request timed out"))?;
    stream.set_read_timeout(Some(remaining))?;
    stream.read(buffer)
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;

    const NOW: i64 = 1_783_933_200;

    fn test_cluster() -> Arc<ClusterService> {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir()
            .join(format!(
                "elink-tui-hooks-cluster-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
            ))
            .join("cluster.json");
        Arc::new(ClusterService::load(path, Some("test-node")).expect("load cluster state"))
    }

    fn status(state: &str) -> ProviderStatus {
        ProviderStatus {
            status: state.to_string(),
            ..ProviderStatus::default()
        }
    }

    #[test]
    fn permission_events_set_attention_for_five_minutes() {
        let registry = HookRegistry::default();
        registry.record("claude", "PermissionRequest", None, NOW);

        let mut value = status("idle");
        registry.apply("claude", &mut value, NOW + 299);
        assert!(value.needs_input);
        registry.apply("claude", &mut value, NOW + 300);
        assert!(!value.needs_input);
    }

    #[test]
    fn permissionish_notification_sets_attention() {
        let registry = HookRegistry::default();
        registry.record("codex", "Notification", Some("Approve this tool?"), NOW);
        let mut value = status("idle");
        registry.apply("codex", &mut value, NOW + 1);
        assert!(value.needs_input);

        let registry = HookRegistry::default();
        registry.record("codex", "Notification", Some("build finished"), NOW);
        registry.apply("codex", &mut value, NOW + 1);
        assert!(!value.needs_input);
    }

    #[test]
    fn working_hook_overrides_state_for_ten_minutes() {
        let registry = HookRegistry::default();
        registry.record("claude", "PreToolUse", None, NOW);

        let mut value = status("idle");
        registry.apply("claude", &mut value, NOW + 599);
        assert_eq!(value.status, "working");

        let mut value = status("idle");
        registry.apply("claude", &mut value, NOW + 600);
        assert_eq!(value.status, "idle");
    }

    #[test]
    fn fresh_idle_hook_downgrades_working_state() {
        let registry = HookRegistry::default();
        registry.record("claude", "Stop", None, NOW);

        let mut value = status("working");
        registry.apply("claude", &mut value, NOW + 59);
        assert_eq!(value.status, "idle");

        let mut value = status("working");
        registry.apply("claude", &mut value, NOW + 60);
        assert_eq!(value.status, "working");
    }

    #[test]
    fn concrete_events_clear_attention_and_unknown_agents_are_ignored() {
        let registry = HookRegistry::default();
        registry.record("claude", "PermissionRequest", None, NOW);
        registry.record("claude", "PostToolUse", None, NOW + 1);
        let mut value = status("idle");
        registry.apply("claude", &mut value, NOW + 2);
        assert!(!value.needs_input);
        assert_eq!(value.status, "working");

        registry.record("gemini", "PreToolUse", None, NOW);
        let mut value = status("idle");
        registry.apply("gemini", &mut value, NOW + 1);
        assert_eq!(value.status, "working");

        registry.record("unknown", "PreToolUse", None, NOW);
        let mut value = status("idle");
        registry.apply("unknown", &mut value, NOW + 1);
        assert_eq!(value.status, "idle");
    }

    fn send(address: SocketAddr, request: &str) -> String {
        let mut stream = TcpStream::connect(address).expect("connect");
        write!(stream, "{request}").expect("send request");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read");
        response
    }

    #[test]
    fn dropping_listener_releases_port() {
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::new(HookRegistry::default()),
            SharedStatus::default(),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();

        drop(listener);

        TcpListener::bind(address).expect("listener port must be reusable after drop");
    }

    #[test]
    fn listener_bounds_concurrent_requests() {
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::new(HookRegistry::default()),
            SharedStatus::default(),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();
        let mut stalled = Vec::new();
        for _ in 0..32 {
            let mut stream = TcpStream::connect(address).expect("connect stalled client");
            stream.write_all(b"G").expect("start incomplete request");
            stalled.push(stream);
        }
        let wait_until = Instant::now() + Duration::from_secs(1);
        while listener.active.load(Ordering::Relaxed) < MAX_CONCURRENT_REQUESTS {
            let active = listener.active.load(Ordering::Relaxed);
            assert!(
                Instant::now() < wait_until,
                "listener accepted only {active} stalled clients"
            );
            thread::sleep(Duration::from_millis(1));
        }

        let mut probe = TcpStream::connect(address).expect("connect probe");
        probe
            .set_read_timeout(Some(Duration::from_millis(500)))
            .expect("set probe timeout");
        let _ = probe.write_all(b"GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n");
        let mut response = String::new();
        let _ = probe.read_to_string(&mut response);

        assert!(!response.starts_with("HTTP/1.1 200"), "{response}");
        drop(stalled);
    }

    #[test]
    fn listener_request_deadline_cannot_be_extended_by_slow_reads() {
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::new(HookRegistry::default()),
            SharedStatus::default(),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();
        let mut stream = TcpStream::connect(address).expect("connect slow client");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("set response timeout");
        for byte in [b"G", b"E", b"T", b" ", b"/", b"v"] {
            if stream.write_all(byte).is_err() {
                break;
            }
            thread::sleep(Duration::from_secs(1));
        }
        let _ = stream.write_all(b"1/health HTTP/1.1\r\nHost: x\r\n\r\n");
        let mut response = String::new();
        let _ = stream.read_to_string(&mut response);

        assert!(!response.starts_with("HTTP/1.1 200"), "{response}");
    }

    #[test]
    fn listener_serves_latest_status_snapshot() {
        let registry = Arc::new(HookRegistry::default());
        let status = SharedStatus::default();
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::clone(&registry),
            Arc::clone(&status),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();

        let response = send(address, "GET /v1/status HTTP/1.1\r\nHost: x\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 503"), "{response}");

        *status.lock().unwrap() = Some(r#"{"schema_version":1}"#.to_string());
        let response = send(address, "GET /v1/status HTTP/1.1\r\nHost: x\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.ends_with(r#"{"schema_version":1}"#), "{response}");
    }

    #[test]
    fn listener_accepts_bridge_style_events() {
        let registry = Arc::new(HookRegistry::default());
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::clone(&registry),
            SharedStatus::default(),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();

        let body = r#"{"agent":"claude","event":"PermissionRequest"}"#;
        let mut stream = TcpStream::connect(address).expect("connect");
        write!(
            stream,
            "POST /v1/event HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        )
        .expect("send request");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read response");
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.contains(r#"{"ok":true}"#));

        let mut value = status("idle");
        registry.apply("claude", &mut value, crate::util::epoch_now());
        assert!(value.needs_input);
    }

    #[test]
    fn listener_rejects_unknown_paths_and_bad_json() {
        let registry = Arc::new(HookRegistry::default());
        let listener = spawn_listener(
            "127.0.0.1:0",
            Arc::clone(&registry),
            SharedStatus::default(),
            test_cluster(),
        )
        .expect("bind test listener");
        let address = listener.local_addr();

        let mut stream = TcpStream::connect(address).expect("connect");
        write!(stream, "GET /v1/preview.png HTTP/1.1\r\nHost: x\r\n\r\n").expect("send request");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read");
        assert!(response.starts_with("HTTP/1.1 404"), "{response}");

        let mut stream = TcpStream::connect(address).expect("connect");
        write!(
            stream,
            "POST /v1/event HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\nnot-json!"
        )
        .expect("send request");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read");
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
    }
}
