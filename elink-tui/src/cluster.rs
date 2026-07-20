use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use base64::prelude::*;
use chrono::{Local, Utc};
use chrono_tz::Tz;
use clap::Subcommand;
use ring::rand::{SecureRandom, SystemRandom};
use ring::{aead, agreement, digest, hkdf, hmac};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

use crate::model::{Cluster, ModelUsage, ProviderStatus, Snapshot};
use crate::source::local::history::{DayTotals, History};
use crate::source::local::store::write_restricted;
use crate::util::epoch_now;

const PROTOCOL_VERSION: u32 = 2;
const PAIRING_CODE_LENGTH: usize = 16;
const PAIRING_TTL_SECONDS: i64 = 120;
const MAX_PAIRING_ATTEMPTS: u8 = 5;
const MAX_PULL_KEYS: usize = 200;
const MAX_HTTP_BODY_BYTES: usize = 8 * 1024 * 1024;
const ONLINE_SECONDS: i64 = 90;
const LIVE_RETENTION_SECONDS: i64 = 7 * 24 * 60 * 60;
const REPLAY_RETENTION_SECONDS: i64 = 5 * 60;
const SIGNATURE_CLOCK_SKEW_SECONDS: i64 = 60;
const USAGE_ERROR_TOLERANCE_SECONDS: i64 = 10 * 60;
const PAIRING_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";

#[derive(Debug, Subcommand)]
pub enum ClusterCommand {
    /// Create a new cluster using this machine as its first node
    Create,
    /// Join an existing mac-app/elink-tui cluster
    Join {
        #[arg(long)]
        endpoint: String,
        #[arg(long)]
        code: String,
    },
    /// Leave the current cluster and discard data learned from peers
    Leave,
    /// Add a manually reachable peer endpoint
    AddPeer {
        #[arg(long)]
        endpoint: String,
    },
    /// Print the local cluster identity and known nodes (never the secret)
    Status,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct ClusterSnapshotKey {
    pub origin_node_id: String,
    pub day: String,
    pub provider: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClusterSnapshotDescriptor {
    pub key: ClusterSnapshotKey,
    pub revision: i64,
    pub content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClusterUsageSnapshot {
    pub key: ClusterSnapshotKey,
    pub revision: i64,
    pub observed_at: f64,
    pub models: BTreeMap<String, i64>,
}

impl ClusterUsageSnapshot {
    fn descriptor(&self) -> ClusterSnapshotDescriptor {
        ClusterSnapshotDescriptor {
            key: self.key.clone(),
            revision: self.revision,
            content_hash: content_hash(&self.models),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClusterNodeRecord {
    pub node_id: String,
    pub name: String,
    pub endpoint: Option<String>,
    pub last_seen_at: Option<f64>,
    pub last_sync_at: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
struct ClusterUsageWindow {
    percent: Option<f64>,
    reset_minutes: Option<i64>,
    reset_at: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
struct ClusterAgentStatus {
    state: String,
    tokens_today: i64,
    model_usage_today: Vec<ClusterModelUsage>,
    primary: ClusterUsageWindow,
    weekly: ClusterUsageWindow,
    needs_input: bool,
    error: Option<String>,
    usage_fetched_at: Option<f64>,
    usage_cached: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct ClusterModelUsage {
    model: String,
    tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ClusterLiveStatus {
    node_id: String,
    node_name: String,
    observed_at: f64,
    claude: ClusterAgentStatus,
    codex: ClusterAgentStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterManifest {
    protocol_version: u32,
    cluster_id: String,
    sender_node_id: String,
    sender_name: String,
    live_statuses: Vec<ClusterLiveStatus>,
    snapshots: Vec<ClusterSnapshotDescriptor>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClusterPullRequest {
    keys: Vec<ClusterSnapshotKey>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClusterPullResponse {
    snapshots: Vec<ClusterUsageSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClusterAnnounce {
    descriptors: Vec<ClusterSnapshotDescriptor>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClusterAck {
    ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterSecurePayload {
    sender_node_id: String,
    sealed: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterJoinRequest {
    proof: String,
    client_node_id: String,
    client_name: String,
    client_public_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterJoinSecret {
    cluster_id: String,
    cluster_secret: String,
    timezone: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterJoinResponse {
    server_public_key: String,
    sealed: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClusterCredentials {
    node_id: String,
    node_name: String,
    cluster_id: Option<String>,
    cluster_secret: Option<String>,
    timezone: Option<String>,
}

impl ClusterCredentials {
    fn clustered(&self) -> bool {
        self.cluster_id.is_some() && cluster_key(self).is_ok()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct StoredClusterState {
    version: u32,
    credentials: ClusterCredentials,
    peers: Vec<String>,
    snapshots: Vec<ClusterUsageSnapshot>,
    nodes: Vec<ClusterNodeRecord>,
}

impl Default for StoredClusterState {
    fn default() -> Self {
        Self {
            version: 1,
            credentials: ClusterCredentials {
                node_id: String::new(),
                node_name: String::new(),
                cluster_id: None,
                cluster_secret: None,
                timezone: None,
            },
            peers: Vec::new(),
            snapshots: Vec::new(),
            nodes: Vec::new(),
        }
    }
}

struct PairingState {
    code: String,
    private_key: Option<agreement::EphemeralPrivateKey>,
    public_key: Vec<u8>,
    expires_at: i64,
    attempts: u8,
}

struct RuntimeState {
    stored: StoredClusterState,
    live_statuses: HashMap<String, ClusterLiveStatus>,
    replay_nonces: HashMap<String, i64>,
    pairing: Option<PairingState>,
    pending_announcements: Vec<ClusterSnapshotDescriptor>,
    generation: u64,
    last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ClusterView {
    pub enabled: bool,
    pub node_id: String,
    pub node_name: String,
    pub cluster_id: Option<String>,
    pub timezone: Option<String>,
    pub pairing_code: Option<String>,
    pub pairing_seconds: Option<i64>,
    pub nodes: Vec<ClusterNodeRecord>,
    pub last_error: Option<String>,
}

pub struct ClusterService {
    path: PathBuf,
    state: Mutex<RuntimeState>,
    force_sync: AtomicBool,
    worker_started: AtomicBool,
}

pub struct ClusterHttpRequest {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
    pub peer_host: String,
    pub local_port: u16,
}

pub struct ClusterHttpResponse {
    pub status: u16,
    pub reason: &'static str,
    pub body: Vec<u8>,
}

impl ClusterHttpResponse {
    fn json<T: Serialize>(value: &T) -> Self {
        match serde_json::to_vec(value) {
            Ok(body) => Self {
                status: 200,
                reason: "OK",
                body,
            },
            Err(_) => Self::error(500, "serialization failed"),
        }
    }

    fn error(status: u16, message: &str) -> Self {
        let reason = match status {
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            409 => "Conflict",
            426 => "Upgrade Required",
            _ => "Internal Server Error",
        };
        let body = serde_json::to_vec(&serde_json::json!({"error": message}))
            .unwrap_or_else(|_| b"{}".to_vec());
        Self {
            status,
            reason,
            body,
        }
    }
}

impl ClusterService {
    pub fn load(path: PathBuf, configured_name: Option<&str>) -> Result<Self> {
        let mut stored = match fs::read(&path) {
            Ok(data) => serde_json::from_slice::<StoredClusterState>(&data)
                .with_context(|| format!("invalid cluster state {}", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                StoredClusterState::default()
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("cannot read cluster state {}", path.display()))
            }
        };
        if stored.credentials.node_id.is_empty() {
            stored.credentials.node_id = random_uuid()?;
        }
        if let Some(name) = configured_name
            .map(str::trim)
            .filter(|name| !name.is_empty())
        {
            stored.credentials.node_name = name.to_string();
        } else if stored.credentials.node_name.is_empty() {
            stored.credentials.node_name = default_node_name();
        }
        stored.peers.sort();
        stored.peers.dedup();
        let service = Self {
            path,
            state: Mutex::new(RuntimeState {
                stored,
                live_statuses: HashMap::new(),
                replay_nonces: HashMap::new(),
                pairing: None,
                pending_announcements: Vec::new(),
                generation: 0,
                last_error: None,
            }),
            force_sync: AtomicBool::new(false),
            worker_started: AtomicBool::new(false),
        };
        {
            let state = service.lock();
            service.save_locked(&state)?;
        }
        Ok(service)
    }

    pub fn run_command(&self, command: &ClusterCommand) -> Result<String> {
        match command {
            ClusterCommand::Create => {
                let cluster_id = self.create_cluster()?;
                Ok(format!("created cluster {cluster_id}"))
            }
            ClusterCommand::Join { endpoint, code } => {
                self.join_cluster(endpoint, code)?;
                Ok(format!(
                    "joined cluster via {}",
                    normalize_endpoint(endpoint)?
                ))
            }
            ClusterCommand::Leave => {
                self.leave_cluster()?;
                Ok("left cluster".to_string())
            }
            ClusterCommand::AddPeer { endpoint } => {
                let endpoint = self.add_peer(endpoint)?;
                Ok(format!("added peer {endpoint}"))
            }
            ClusterCommand::Status => Ok(self.status_text()),
        }
    }

    pub fn create_cluster(&self) -> Result<String> {
        let mut state = self.lock();
        if state.stored.credentials.clustered() {
            bail!("already joined to a cluster; leave it before creating another");
        }
        let cluster_id = random_uuid()?;
        state.stored.credentials.cluster_id = Some(cluster_id.clone());
        state.stored.credentials.cluster_secret = Some(BASE64_STANDARD.encode(random_bytes(32)?));
        state.stored.credentials.timezone = Some(local_timezone_name());
        reset_remote_data(&mut state);
        state.generation += 1;
        self.save_locked(&state)?;
        Ok(cluster_id)
    }

    pub fn leave_cluster(&self) -> Result<()> {
        let mut state = self.lock();
        state.stored.credentials.cluster_id = None;
        state.stored.credentials.cluster_secret = None;
        state.stored.credentials.timezone = None;
        state.stored.peers.clear();
        reset_remote_data(&mut state);
        state.live_statuses.clear();
        state.pairing = None;
        state.generation += 1;
        self.save_locked(&state)
    }

    pub fn add_peer(&self, endpoint: &str) -> Result<String> {
        let endpoint = normalize_endpoint(endpoint)?;
        let mut state = self.lock();
        if !state.stored.peers.contains(&endpoint) {
            state.stored.peers.push(endpoint.clone());
            state.stored.peers.sort();
            self.save_locked(&state)?;
        }
        self.force_sync.store(true, Ordering::Release);
        Ok(endpoint)
    }

    pub fn start_pairing(&self) -> Result<String> {
        let rng = SystemRandom::new();
        let private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
            .map_err(|_| anyhow!("cannot generate pairing key"))?;
        let public_key = private_key
            .compute_public_key()
            .map_err(|_| anyhow!("cannot derive pairing public key"))?
            .as_ref()
            .to_vec();
        let code = generate_pairing_code()?;
        let mut state = self.lock();
        if !state.stored.credentials.clustered() {
            bail!("create or join a cluster before starting pairing");
        }
        state.pairing = Some(PairingState {
            code: code.clone(),
            private_key: Some(private_key),
            public_key,
            expires_at: epoch_now() + PAIRING_TTL_SECONDS,
            attempts: 0,
        });
        Ok(format_pairing_code(&code))
    }

    pub fn request_sync(&self) {
        self.force_sync.store(true, Ordering::Release);
    }

    pub fn bucket_timezone(&self) -> Option<Tz> {
        self.lock()
            .stored
            .credentials
            .timezone
            .as_deref()
            .and_then(|value| Tz::from_str(value).ok())
    }

    pub fn day_key(&self, timestamp: i64) -> String {
        crate::source::local::sessions::day_key_in(timestamp, self.bucket_timezone())
    }

    pub fn view(&self) -> ClusterView {
        let now = epoch_now();
        let mut state = self.lock();
        if state
            .pairing
            .as_ref()
            .is_some_and(|pairing| pairing.expires_at <= now)
        {
            state.pairing = None;
        }
        let pairing = state.pairing.as_ref();
        ClusterView {
            enabled: state.stored.credentials.clustered(),
            node_id: state.stored.credentials.node_id.clone(),
            node_name: state.stored.credentials.node_name.clone(),
            cluster_id: state.stored.credentials.cluster_id.clone(),
            timezone: state.stored.credentials.timezone.clone(),
            pairing_code: pairing.map(|value| format_pairing_code(&value.code)),
            pairing_seconds: pairing.map(|value| (value.expires_at - now).max(0)),
            nodes: state.stored.nodes.clone(),
            last_error: state.last_error.clone(),
        }
    }

    fn status_text(&self) -> String {
        let view = self.view();
        let mut lines = vec![
            format!("enabled: {}", view.enabled),
            format!("node_id: {}", view.node_id),
            format!("node_name: {}", view.node_name),
            format!("cluster_id: {}", view.cluster_id.as_deref().unwrap_or("-")),
            format!("timezone: {}", view.timezone.as_deref().unwrap_or("-")),
            format!("nodes: {}", view.nodes.len()),
        ];
        for node in view.nodes {
            lines.push(format!(
                "- {} ({}) {}",
                node.name,
                node.node_id,
                node.endpoint.as_deref().unwrap_or("local")
            ));
        }
        lines.join("\n")
    }

    fn lock(&self) -> MutexGuard<'_, RuntimeState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn save_locked(&self, state: &RuntimeState) -> Result<()> {
        let text = serde_json::to_string(&state.stored)?;
        write_restricted(&self.path, &text)
            .with_context(|| format!("cannot write cluster state {}", self.path.display()))
    }
}

fn reset_remote_data(state: &mut RuntimeState) {
    let local = state.stored.credentials.node_id.clone();
    state
        .stored
        .snapshots
        .retain(|snapshot| snapshot.key.origin_node_id == local);
    state.stored.nodes.retain(|node| node.node_id == local);
    state.pending_announcements.clear();
}

fn default_node_name() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Linux".to_string())
}

fn local_timezone_name() -> String {
    if let Ok(value) = std::env::var("TZ") {
        if Tz::from_str(&value).is_ok() {
            return value;
        }
    }
    if let Ok(value) = fs::read_to_string("/etc/timezone") {
        let value = value.trim();
        if Tz::from_str(value).is_ok() {
            return value.to_string();
        }
    }
    if let Ok(target) = fs::read_link("/etc/localtime") {
        let text = target.to_string_lossy();
        if let Some((_, value)) = text.split_once("zoneinfo/") {
            if Tz::from_str(value).is_ok() {
                return value.to_string();
            }
        }
    }
    "UTC".to_string()
}

fn normalize_endpoint(value: &str) -> Result<String> {
    let mut text = value.trim().trim_end_matches('/').to_string();
    if text.is_empty() {
        bail!("peer endpoint is empty");
    }
    if !text.starts_with("http://") {
        text = format!("http://{text}");
    }
    if text.starts_with("https://") || !text.starts_with("http://") {
        bail!("cluster endpoints must use http://");
    }
    let authority = text.trim_start_matches("http://");
    if authority.is_empty()
        || authority.contains('/')
        || authority.contains('?')
        || authority.contains('#')
    {
        bail!("invalid peer endpoint {value:?}");
    }
    if !authority.starts_with('[') && authority.matches(':').count() > 1 {
        bail!("IPv6 peer endpoints must use brackets");
    }
    let has_port = if authority.starts_with('[') {
        authority
            .rsplit_once(']')
            .is_some_and(|(_, suffix)| suffix.starts_with(':'))
    } else {
        authority
            .rsplit_once(':')
            .is_some_and(|(_, port)| port.parse::<u16>().is_ok())
    };
    if !has_port {
        text.push_str(":8765");
    }
    Ok(text)
}

fn peer_endpoint(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("http://[{host}]:{port}")
    } else {
        format!("http://{host}:{port}")
    }
}

fn content_hash(models: &BTreeMap<String, i64>) -> String {
    let canonical = models
        .iter()
        .filter(|(_, tokens)| **tokens > 0)
        .map(|(model, tokens)| format!("{model}={tokens}"))
        .collect::<Vec<_>>()
        .join("\n");
    BASE64_STANDARD.encode(digest::digest(&digest::SHA256, canonical.as_bytes()).as_ref())
}

fn random_bytes(count: usize) -> Result<Vec<u8>> {
    let mut bytes = vec![0u8; count];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| anyhow!("secure random generator failed"))?;
    Ok(bytes)
}

fn random_uuid() -> Result<String> {
    let mut bytes: [u8; 16] = random_bytes(16)?.try_into().expect("requested 16 bytes");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

fn generate_pairing_code() -> Result<String> {
    let mut result = String::new();
    while result.len() < PAIRING_CODE_LENGTH {
        for byte in random_bytes(32)? {
            if result.len() == PAIRING_CODE_LENGTH {
                break;
            }
            if byte < 240 {
                result.push(PAIRING_ALPHABET[usize::from(byte) % PAIRING_ALPHABET.len()] as char);
            }
        }
    }
    Ok(result)
}

fn normalize_pairing_code(value: &str) -> Result<String> {
    let code: String = value
        .to_ascii_uppercase()
        .chars()
        .filter(|character| *character != '-' && *character != ' ')
        .collect();
    if code.len() != PAIRING_CODE_LENGTH
        || !code.bytes().all(|byte| PAIRING_ALPHABET.contains(&byte))
    {
        bail!("pairing code must contain 16 valid characters");
    }
    Ok(code)
}

fn format_pairing_code(code: &str) -> String {
    code.as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

#[derive(Clone, Copy)]
struct KeyLength(usize);

impl hkdf::KeyType for KeyLength {
    fn len(&self) -> usize {
        self.0
    }
}

fn sha256(data: &[u8]) -> Vec<u8> {
    digest::digest(&digest::SHA256, data).as_ref().to_vec()
}

fn hkdf_sha256(input: &[u8], salt: &[u8], info: &[u8]) -> Result<[u8; 32]> {
    let salt = hkdf::Salt::new(hkdf::HKDF_SHA256, salt);
    let prk = salt.extract(input);
    let info_parts = [info];
    let okm = prk
        .expand(&info_parts, KeyLength(32))
        .map_err(|_| anyhow!("HKDF expansion failed"))?;
    let mut output = [0u8; 32];
    okm.fill(&mut output)
        .map_err(|_| anyhow!("HKDF output failed"))?;
    Ok(output)
}

fn cluster_key(credentials: &ClusterCredentials) -> Result<[u8; 32]> {
    let encoded = credentials
        .cluster_secret
        .as_deref()
        .ok_or_else(|| anyhow!("cluster secret is missing"))?;
    let decoded = BASE64_STANDARD
        .decode(encoded)
        .map_err(|_| anyhow!("cluster secret is invalid"))?;
    decoded
        .get(..32)
        .ok_or_else(|| anyhow!("cluster secret is too short"))?
        .try_into()
        .map_err(|_| anyhow!("cluster secret is invalid"))
}

fn derived_key(key: &[u8; 32], purpose: &str) -> Result<[u8; 32]> {
    hkdf_sha256(key, b"elink-ai-cluster-v2", purpose.as_bytes())
}

fn pairing_proof(code: &str, public_key: &[u8], node_id: &str) -> String {
    let key = hmac::Key::new(hmac::HMAC_SHA256, &sha256(code.as_bytes()));
    let mut payload = public_key.to_vec();
    payload.extend_from_slice(node_id.as_bytes());
    BASE64_STANDARD.encode(hmac::sign(&key, &payload).as_ref())
}

fn pairing_key(
    private_key: agreement::EphemeralPrivateKey,
    peer_public_key: &[u8],
    code: &str,
) -> Result<[u8; 32]> {
    let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, peer_public_key);
    let shared = agreement::agree_ephemeral(private_key, &peer, |material| material.to_vec())
        .map_err(|_| anyhow!("invalid peer pairing key"))?;
    hkdf_sha256(&shared, &sha256(code.as_bytes()), b"elink-ai-pair-v2")
}

fn seal<T: Serialize>(value: &T, key: &[u8; 32], sender_node_id: &str) -> Result<Vec<u8>> {
    let encryption_key = derived_key(key, "encryption")?;
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, &encryption_key)
        .map_err(|_| anyhow!("invalid encryption key"))?;
    let key = aead::LessSafeKey::new(unbound);
    let nonce_bytes: [u8; 12] = random_bytes(12)?.try_into().expect("requested 12 bytes");
    let nonce = aead::Nonce::assume_unique_for_key(nonce_bytes);
    let mut encrypted = serde_json::to_vec(value)?;
    key.seal_in_place_append_tag(
        nonce,
        aead::Aad::from(sender_node_id.as_bytes()),
        &mut encrypted,
    )
    .map_err(|_| anyhow!("payload encryption failed"))?;
    let mut combined = nonce_bytes.to_vec();
    combined.extend_from_slice(&encrypted);
    serde_json::to_vec(&ClusterSecurePayload {
        sender_node_id: sender_node_id.to_string(),
        sealed: BASE64_STANDARD.encode(combined),
    })
    .map_err(Into::into)
}

fn open<T: DeserializeOwned>(data: &[u8], key: &[u8; 32]) -> Result<(String, T)> {
    let envelope: ClusterSecurePayload = serde_json::from_slice(data)?;
    let combined = BASE64_STANDARD
        .decode(&envelope.sealed)
        .map_err(|_| anyhow!("secure payload is not base64"))?;
    if combined.len() < 12 + aead::AES_256_GCM.tag_len() {
        bail!("secure payload is too short");
    }
    let nonce_bytes: [u8; 12] = combined[..12].try_into().expect("checked nonce length");
    let mut encrypted = combined[12..].to_vec();
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, &derived_key(key, "encryption")?)
        .map_err(|_| anyhow!("invalid encryption key"))?;
    let key = aead::LessSafeKey::new(unbound);
    let plaintext = key
        .open_in_place(
            aead::Nonce::assume_unique_for_key(nonce_bytes),
            aead::Aad::from(envelope.sender_node_id.as_bytes()),
            &mut encrypted,
        )
        .map_err(|_| anyhow!("secure payload authentication failed"))?;
    Ok((envelope.sender_node_id, serde_json::from_slice(plaintext)?))
}

fn signed_headers(
    method: &str,
    path: &str,
    body: &[u8],
    node_id: &str,
    key: &[u8; 32],
    timestamp: i64,
    nonce: &str,
) -> Result<HashMap<String, String>> {
    let canonical = format!(
        "{}\n{}\n{}\n{}\n{}",
        method.to_ascii_uppercase(),
        path,
        timestamp,
        nonce,
        BASE64_STANDARD.encode(sha256(body))
    );
    let auth_key = hmac::Key::new(hmac::HMAC_SHA256, &derived_key(key, "authentication")?);
    let signature = BASE64_STANDARD.encode(hmac::sign(&auth_key, canonical.as_bytes()).as_ref());
    Ok(HashMap::from([
        ("X-Elink-Node".to_string(), node_id.to_string()),
        ("X-Elink-Timestamp".to_string(), timestamp.to_string()),
        ("X-Elink-Nonce".to_string(), nonce.to_string()),
        ("X-Elink-Signature".to_string(), signature),
    ]))
}

fn verify_headers(
    request: &ClusterHttpRequest,
    key: &[u8; 32],
    now: i64,
) -> Result<(String, String)> {
    let header = |name: &str| {
        request
            .headers
            .get(name)
            .map(String::as_str)
            .ok_or_else(|| anyhow!("missing authentication header"))
    };
    let node_id = header("x-elink-node")?.to_string();
    let timestamp: i64 = header("x-elink-timestamp")?
        .parse()
        .map_err(|_| anyhow!("invalid authentication timestamp"))?;
    if (now - timestamp).abs() > SIGNATURE_CLOCK_SKEW_SECONDS {
        bail!("authentication timestamp is outside the allowed window");
    }
    let nonce = header("x-elink-nonce")?.to_string();
    let supplied = BASE64_STANDARD
        .decode(header("x-elink-signature")?)
        .map_err(|_| anyhow!("invalid authentication signature"))?;
    let canonical = format!(
        "{}\n{}\n{}\n{}\n{}",
        request.method.to_ascii_uppercase(),
        request.path,
        timestamp,
        nonce,
        BASE64_STANDARD.encode(sha256(&request.body))
    );
    let auth_key = hmac::Key::new(hmac::HMAC_SHA256, &derived_key(key, "authentication")?);
    hmac::verify(&auth_key, canonical.as_bytes(), &supplied)
        .map_err(|_| anyhow!("authentication signature mismatch"))?;
    Ok((node_id, nonce))
}

impl ClusterService {
    pub fn join_cluster(&self, endpoint: &str, code: &str) -> Result<()> {
        let endpoint = normalize_endpoint(endpoint)?;
        let code = normalize_pairing_code(code)?;
        let rng = SystemRandom::new();
        let private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
            .map_err(|_| anyhow!("cannot generate pairing key"))?;
        let public_key = private_key
            .compute_public_key()
            .map_err(|_| anyhow!("cannot derive pairing public key"))?
            .as_ref()
            .to_vec();
        let credentials = self.lock().stored.credentials.clone();
        let join = ClusterJoinRequest {
            proof: pairing_proof(&code, &public_key, &credentials.node_id),
            client_node_id: credentials.node_id.clone(),
            client_name: credentials.node_name.clone(),
            client_public_key: BASE64_STANDARD.encode(&public_key),
        };
        let body = serde_json::to_vec(&join)?;
        let agent = network_agent(Duration::from_secs(10));
        let response = agent
            .post(&format!("{endpoint}/v3/cluster/pair/join"))
            .set("Content-Type", "application/json")
            .send_bytes(&body);
        let response = match response {
            Ok(response) => response,
            Err(ureq::Error::Status(426, _)) => {
                bail!("peer uses an incompatible pairing protocol")
            }
            Err(ureq::Error::Status(code, _)) => {
                bail!("pairing rejected by peer: HTTP {code}")
            }
            Err(ureq::Error::Transport(_)) => bail!("pairing peer is unreachable"),
        };
        let data = read_response(response)?;
        let joined: ClusterJoinResponse =
            serde_json::from_slice(&data).context("invalid pairing response")?;
        let server_public = BASE64_STANDARD
            .decode(joined.server_public_key)
            .map_err(|_| anyhow!("invalid server pairing key"))?;
        let sealed = BASE64_STANDARD
            .decode(joined.sealed)
            .map_err(|_| anyhow!("invalid sealed cluster credentials"))?;
        let key = pairing_key(private_key, &server_public, &code)?;
        let (_, secret): (String, ClusterJoinSecret) = open(&sealed, &key)?;
        if secret.cluster_id.is_empty()
            || BASE64_STANDARD
                .decode(&secret.cluster_secret)
                .ok()
                .is_none_or(|value| value.len() < 32)
            || Tz::from_str(&secret.timezone).is_err()
        {
            bail!("peer returned invalid cluster credentials");
        }
        let mut state = self.lock();
        state.stored.credentials.cluster_id = Some(secret.cluster_id);
        state.stored.credentials.cluster_secret = Some(secret.cluster_secret);
        state.stored.credentials.timezone = Some(secret.timezone);
        state.stored.peers = vec![endpoint];
        reset_remote_data(&mut state);
        state.live_statuses.clear();
        state.replay_nonces.clear();
        state.generation += 1;
        self.save_locked(&state)?;
        self.force_sync.store(true, Ordering::Release);
        Ok(())
    }

    pub fn handle_http(&self, request: ClusterHttpRequest) -> ClusterHttpResponse {
        match (request.method.as_str(), request.path.as_str()) {
            ("POST", "/v2/cluster/pair/join") => {
                ClusterHttpResponse::error(426, "pairing protocol upgraded; update both apps")
            }
            ("POST", "/v3/cluster/pair/join") => self.handle_join(request),
            ("GET", "/v2/cluster/manifest") => self.handle_manifest(request),
            ("POST", "/v2/cluster/pull") => self.handle_pull(request),
            ("POST", "/v2/cluster/announce") => self.handle_announce(request),
            _ => ClusterHttpResponse::error(400, "unknown cluster route"),
        }
    }

    fn handle_join(&self, request: ClusterHttpRequest) -> ClusterHttpResponse {
        let join: ClusterJoinRequest = match serde_json::from_slice(&request.body) {
            Ok(join) => join,
            Err(_) => return ClusterHttpResponse::error(400, "invalid pairing request"),
        };
        let client_public = match BASE64_STANDARD.decode(&join.client_public_key) {
            Ok(key) if key.len() == 32 => key,
            _ => return ClusterHttpResponse::error(400, "invalid pairing request"),
        };
        if join.client_node_id.is_empty()
            || join.client_node_id.len() > 256
            || join.client_name.is_empty()
            || join.client_name.len() > 1024
        {
            return ClusterHttpResponse::error(400, "invalid pairing request");
        }
        let now = epoch_now();
        let (private_key, public_key, code, credentials, generation) = {
            let mut state = self.lock();
            let Some(pairing) = state.pairing.as_mut() else {
                return ClusterHttpResponse::error(403, "pairing code rejected");
            };
            if pairing.expires_at <= now || pairing.attempts >= MAX_PAIRING_ATTEMPTS {
                state.pairing = None;
                return ClusterHttpResponse::error(403, "pairing code rejected");
            }
            pairing.attempts += 1;
            let expected = pairing_proof(&pairing.code, &client_public, &join.client_node_id);
            if !constant_time_equal(expected.as_bytes(), join.proof.as_bytes()) {
                return ClusterHttpResponse::error(403, "pairing code rejected");
            }
            let Some(private_key) = pairing.private_key.take() else {
                return ClusterHttpResponse::error(403, "pairing code rejected");
            };
            (
                private_key,
                pairing.public_key.clone(),
                pairing.code.clone(),
                state.stored.credentials.clone(),
                state.generation,
            )
        };
        let Some(cluster_id) = credentials.cluster_id.clone() else {
            return ClusterHttpResponse::error(409, "cluster unavailable");
        };
        let Some(cluster_secret) = credentials.cluster_secret.clone() else {
            return ClusterHttpResponse::error(409, "cluster unavailable");
        };
        let Some(timezone) = credentials.timezone.clone() else {
            return ClusterHttpResponse::error(409, "cluster unavailable");
        };
        let response = (|| -> Result<ClusterJoinResponse> {
            let key = pairing_key(private_key, &client_public, &code)?;
            let sealed = seal(
                &ClusterJoinSecret {
                    cluster_id,
                    cluster_secret,
                    timezone,
                },
                &key,
                &credentials.node_id,
            )?;
            Ok(ClusterJoinResponse {
                server_public_key: BASE64_STANDARD.encode(public_key),
                sealed: BASE64_STANDARD.encode(sealed),
            })
        })();
        let response = match response {
            Ok(response) => response,
            Err(_) => return ClusterHttpResponse::error(400, "pairing failed"),
        };
        let endpoint = peer_endpoint(&request.peer_host, request.local_port);
        let mut state = self.lock();
        if state.generation != generation || !state.stored.credentials.clustered() {
            return ClusterHttpResponse::error(409, "cluster configuration changed");
        }
        state.pairing = None;
        upsert_node(
            &mut state.stored.nodes,
            ClusterNodeRecord {
                node_id: join.client_node_id,
                name: join.client_name,
                endpoint: Some(endpoint.clone()),
                last_seen_at: Some(now as f64),
                last_sync_at: None,
            },
        );
        if !state.stored.peers.contains(&endpoint) {
            state.stored.peers.push(endpoint);
            state.stored.peers.sort();
        }
        if self.save_locked(&state).is_err() {
            return ClusterHttpResponse::error(500, "pairing state could not be saved");
        }
        self.force_sync.store(true, Ordering::Release);
        ClusterHttpResponse::json(&response)
    }

    fn handle_manifest(&self, request: ClusterHttpRequest) -> ClusterHttpResponse {
        let key = match self.authorize(&request) {
            Ok((_, key)) => key,
            Err(_) => return ClusterHttpResponse::error(401, "unauthorized"),
        };
        let state = self.lock();
        let credentials = &state.stored.credentials;
        let live_statuses = state
            .live_statuses
            .values()
            .filter(|status| {
                epoch_now() as f64 - status.observed_at < LIVE_RETENTION_SECONDS as f64
            })
            .cloned()
            .collect();
        let manifest = ClusterManifest {
            protocol_version: PROTOCOL_VERSION,
            cluster_id: credentials.cluster_id.clone().unwrap_or_default(),
            sender_node_id: credentials.node_id.clone(),
            sender_name: credentials.node_name.clone(),
            live_statuses,
            snapshots: state
                .stored
                .snapshots
                .iter()
                .map(ClusterUsageSnapshot::descriptor)
                .collect(),
        };
        match seal(&manifest, &key, &credentials.node_id) {
            Ok(body) => ClusterHttpResponse {
                status: 200,
                reason: "OK",
                body,
            },
            Err(_) => ClusterHttpResponse::error(500, "encryption failed"),
        }
    }

    fn handle_pull(&self, request: ClusterHttpRequest) -> ClusterHttpResponse {
        let (node_id, key) = match self.authorize(&request) {
            Ok(auth) => auth,
            Err(_) => return ClusterHttpResponse::error(401, "unauthorized"),
        };
        let (sender, pull): (String, ClusterPullRequest) = match open(&request.body, &key) {
            Ok(value) if value.0 == node_id => value,
            _ => return ClusterHttpResponse::error(401, "unauthorized"),
        };
        debug_assert_eq!(sender, node_id);
        let state = self.lock();
        let snapshots = pull
            .keys
            .iter()
            .take(MAX_PULL_KEYS)
            .filter_map(|key| {
                state
                    .stored
                    .snapshots
                    .iter()
                    .find(|snapshot| &snapshot.key == key)
                    .cloned()
            })
            .collect();
        let response = ClusterPullResponse { snapshots };
        match seal(&response, &key, &state.stored.credentials.node_id) {
            Ok(body) => ClusterHttpResponse {
                status: 200,
                reason: "OK",
                body,
            },
            Err(_) => ClusterHttpResponse::error(500, "encryption failed"),
        }
    }

    fn handle_announce(&self, request: ClusterHttpRequest) -> ClusterHttpResponse {
        let (node_id, key) = match self.authorize(&request) {
            Ok(auth) => auth,
            Err(_) => return ClusterHttpResponse::error(401, "unauthorized"),
        };
        let (sender, _): (String, ClusterAnnounce) = match open(&request.body, &key) {
            Ok(value) if value.0 == node_id => value,
            _ => return ClusterHttpResponse::error(401, "unauthorized"),
        };
        debug_assert_eq!(sender, node_id);
        self.force_sync.store(true, Ordering::Release);
        let local_node = self.lock().stored.credentials.node_id.clone();
        match seal(&ClusterAck { ok: true }, &key, &local_node) {
            Ok(body) => ClusterHttpResponse {
                status: 200,
                reason: "OK",
                body,
            },
            Err(_) => ClusterHttpResponse::error(500, "encryption failed"),
        }
    }

    fn authorize(&self, request: &ClusterHttpRequest) -> Result<(String, [u8; 32])> {
        let key = cluster_key(&self.lock().stored.credentials)?;
        let now = epoch_now();
        let (node_id, nonce) = verify_headers(request, &key, now)?;
        if node_id.is_empty() || nonce.is_empty() || nonce.len() > 256 {
            bail!("invalid authentication identity");
        }
        let mut state = self.lock();
        state
            .replay_nonces
            .retain(|_, observed| now - *observed < REPLAY_RETENTION_SECONDS);
        if state.replay_nonces.contains_key(&nonce) {
            bail!("replayed request");
        }
        state.replay_nonces.insert(nonce, now);
        Ok((node_id, key))
    }

    pub fn start_sync_worker(self: &Arc<Self>, interval: Duration) {
        if self.worker_started.swap(true, Ordering::AcqRel) {
            return;
        }
        let weak = Arc::downgrade(self);
        thread::spawn(move || {
            let agent = network_agent(Duration::from_secs(5));
            let mut last_sync = Instant::now()
                .checked_sub(interval)
                .unwrap_or_else(Instant::now);
            loop {
                thread::sleep(Duration::from_secs(1));
                let Some(service) = weak.upgrade() else {
                    break;
                };
                let pending = {
                    let mut state = service.lock();
                    std::mem::take(&mut state.pending_announcements)
                };
                if !pending.is_empty() {
                    service.announce(&agent, pending);
                }
                let due = last_sync.elapsed() >= interval;
                if due || service.force_sync.swap(false, Ordering::AcqRel) {
                    if service.view().enabled {
                        service.sync_all(&agent);
                    }
                    last_sync = Instant::now();
                }
            }
        });
    }

    fn announce(&self, agent: &ureq::Agent, descriptors: Vec<ClusterSnapshotDescriptor>) {
        let (credentials, endpoints) = {
            let state = self.lock();
            (
                state.stored.credentials.clone(),
                known_endpoints(&state.stored),
            )
        };
        let Ok(key) = cluster_key(&credentials) else {
            return;
        };
        let announce = ClusterAnnounce {
            descriptors: descriptors.into_iter().take(MAX_PULL_KEYS).collect(),
        };
        for endpoint in endpoints {
            let Ok(body) = seal(&announce, &key, &credentials.node_id) else {
                continue;
            };
            let path = "/v2/cluster/announce";
            let Ok(headers) = signed_headers(
                "POST",
                path,
                &body,
                &credentials.node_id,
                &key,
                epoch_now(),
                &random_uuid().unwrap_or_default(),
            ) else {
                continue;
            };
            let request = with_headers(
                agent
                    .post(&format!("{endpoint}{path}"))
                    .set("Content-Type", "application/json"),
                &headers,
            );
            let _ = request.send_bytes(&body);
        }
    }

    fn sync_all(&self, agent: &ureq::Agent) {
        let endpoints = known_endpoints(&self.lock().stored);
        let mut first_error = None;
        for endpoint in endpoints {
            if let Err(error) = self.sync_peer(agent, &endpoint) {
                if first_error.is_none() {
                    first_error = Some(error.to_string());
                }
            }
        }
        self.lock().last_error = first_error;
    }

    fn sync_peer(&self, agent: &ureq::Agent, endpoint: &str) -> Result<()> {
        let (credentials, generation) = {
            let state = self.lock();
            (state.stored.credentials.clone(), state.generation)
        };
        let key = cluster_key(&credentials)?;
        let cluster_id = credentials
            .cluster_id
            .clone()
            .ok_or_else(|| anyhow!("cluster ID is missing"))?;
        let path = "/v2/cluster/manifest";
        let headers = signed_headers(
            "GET",
            path,
            &[],
            &credentials.node_id,
            &key,
            epoch_now(),
            &random_uuid()?,
        )?;
        let response = with_headers(agent.get(&format!("{endpoint}{path}")), &headers)
            .call()
            .map_err(|error| network_error(endpoint, error))?;
        let data = read_response(response)?;
        let (_, manifest): (String, ClusterManifest) = open(&data, &key)?;
        if manifest.protocol_version != PROTOCOL_VERSION || manifest.cluster_id != cluster_id {
            bail!("peer {endpoint} does not belong to this cluster");
        }
        if manifest.sender_node_id == credentials.node_id {
            bail!("peer {endpoint} points to this node");
        }
        let missing: Vec<ClusterSnapshotKey> = {
            let state = self.lock();
            manifest
                .snapshots
                .iter()
                .filter(|remote| {
                    state
                        .stored
                        .snapshots
                        .iter()
                        .find(|local| local.key == remote.key)
                        .is_none_or(|local| remote.revision > local.revision)
                })
                .map(|descriptor| descriptor.key.clone())
                .collect()
        };
        for keys in missing.chunks(MAX_PULL_KEYS) {
            let pulled = self.pull(agent, endpoint, &credentials, &key, keys)?;
            self.merge_snapshots(pulled, generation)?;
        }
        let now = epoch_now() as f64;
        let mut state = self.lock();
        if state.generation != generation {
            bail!("cluster configuration changed during synchronization");
        }
        for live in manifest.live_statuses {
            let newer = state
                .live_statuses
                .get(&live.node_id)
                .is_none_or(|current| live.observed_at > current.observed_at);
            if newer {
                state
                    .live_statuses
                    .insert(live.node_id.clone(), live.clone());
            }
            if live.node_id != credentials.node_id {
                upsert_node(
                    &mut state.stored.nodes,
                    ClusterNodeRecord {
                        node_id: live.node_id,
                        name: live.node_name,
                        endpoint: None,
                        last_seen_at: Some(live.observed_at),
                        last_sync_at: None,
                    },
                );
            }
        }
        upsert_node(
            &mut state.stored.nodes,
            ClusterNodeRecord {
                node_id: manifest.sender_node_id,
                name: manifest.sender_name,
                endpoint: Some(endpoint.to_string()),
                last_seen_at: Some(now),
                last_sync_at: Some(now),
            },
        );
        self.save_locked(&state)
    }

    fn pull(
        &self,
        agent: &ureq::Agent,
        endpoint: &str,
        credentials: &ClusterCredentials,
        key: &[u8; 32],
        keys: &[ClusterSnapshotKey],
    ) -> Result<Vec<ClusterUsageSnapshot>> {
        let path = "/v2/cluster/pull";
        let body = seal(
            &ClusterPullRequest {
                keys: keys.to_vec(),
            },
            key,
            &credentials.node_id,
        )?;
        let headers = signed_headers(
            "POST",
            path,
            &body,
            &credentials.node_id,
            key,
            epoch_now(),
            &random_uuid()?,
        )?;
        let request = with_headers(
            agent
                .post(&format!("{endpoint}{path}"))
                .set("Content-Type", "application/json"),
            &headers,
        );
        let response = request
            .send_bytes(&body)
            .map_err(|error| network_error(endpoint, error))?;
        let data = read_response(response)?;
        let (_, pulled): (String, ClusterPullResponse) = open(&data, key)?;
        if pulled.snapshots.len() > MAX_PULL_KEYS {
            bail!("peer returned too many snapshots");
        }
        Ok(pulled.snapshots)
    }

    fn merge_snapshots(&self, snapshots: Vec<ClusterUsageSnapshot>, generation: u64) -> Result<()> {
        let mut state = self.lock();
        if state.generation != generation {
            bail!("cluster configuration changed during synchronization");
        }
        let local_node = state.stored.credentials.node_id.clone();
        for snapshot in snapshots {
            validate_snapshot(&snapshot)?;
            if snapshot.key.origin_node_id == local_node {
                continue;
            }
            match state
                .stored
                .snapshots
                .iter_mut()
                .find(|current| current.key == snapshot.key)
            {
                Some(current) if snapshot.revision > current.revision => *current = snapshot,
                Some(_) => continue,
                None => state.stored.snapshots.push(snapshot),
            }
        }
        self.save_locked(&state)
    }
}

fn network_agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(timeout).build()
}

fn with_headers(mut request: ureq::Request, headers: &HashMap<String, String>) -> ureq::Request {
    for (name, value) in headers {
        request = request.set(name, value);
    }
    request
}

fn read_response(response: ureq::Response) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take((MAX_HTTP_BODY_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_HTTP_BODY_BYTES {
        bail!("cluster response is too large");
    }
    Ok(bytes)
}

fn network_error(endpoint: &str, error: ureq::Error) -> anyhow::Error {
    match error {
        ureq::Error::Status(code, _) => anyhow!("peer {endpoint} returned HTTP {code}"),
        ureq::Error::Transport(_) => anyhow!("peer {endpoint} is unreachable"),
    }
}

fn known_endpoints(stored: &StoredClusterState) -> Vec<String> {
    let mut endpoints = stored.peers.clone();
    endpoints.extend(stored.nodes.iter().filter_map(|node| node.endpoint.clone()));
    endpoints.sort();
    endpoints.dedup();
    endpoints
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in left.iter().zip(right) {
        difference |= left ^ right;
    }
    difference == 0
}

fn validate_snapshot(snapshot: &ClusterUsageSnapshot) -> Result<()> {
    if snapshot.key.origin_node_id.is_empty()
        || snapshot.key.origin_node_id.len() > 256
        || snapshot.key.provider != "claude" && snapshot.key.provider != "codex"
        || chrono::NaiveDate::parse_from_str(&snapshot.key.day, "%Y-%m-%d").is_err()
        || snapshot.revision <= 0
        || !snapshot.observed_at.is_finite()
        || snapshot.models.len() > 4096
        || snapshot
            .models
            .iter()
            .any(|(model, tokens)| model.is_empty() || model.len() > 2048 || *tokens < 0)
    {
        bail!("peer returned an invalid usage snapshot");
    }
    Ok(())
}

fn upsert_node(nodes: &mut Vec<ClusterNodeRecord>, incoming: ClusterNodeRecord) {
    match nodes
        .iter_mut()
        .find(|node| node.node_id == incoming.node_id)
    {
        Some(node) => {
            node.name = incoming.name;
            if incoming.endpoint.is_some() {
                node.endpoint = incoming.endpoint;
            }
            if incoming.last_seen_at > node.last_seen_at {
                node.last_seen_at = incoming.last_seen_at;
            }
            if incoming.last_sync_at > node.last_sync_at {
                node.last_sync_at = incoming.last_sync_at;
            }
        }
        None => nodes.push(incoming),
    }
    nodes.sort_by(|left, right| left.node_id.cmp(&right.node_id));
}

impl ClusterService {
    pub fn aggregate(&self, local: &Snapshot, history: Option<&History>) -> Snapshot {
        let now = epoch_now();
        let mut state = self.lock();
        if !state.stored.credentials.clustered() {
            return local.clone();
        }
        let credentials = state.stored.credentials.clone();
        let today = crate::source::local::sessions::day_key_in(
            now,
            credentials
                .timezone
                .as_deref()
                .and_then(|value| Tz::from_str(value).ok()),
        );
        let mut claude_days = history
            .map(|history| history.provider_days("claude"))
            .unwrap_or_default();
        let mut codex_days = history
            .map(|history| history.provider_days("codex"))
            .unwrap_or_default();
        claude_days.insert(
            today.clone(),
            models_to_map(&local.claude.model_usage_today),
        );
        codex_days.insert(today.clone(), models_to_map(&local.codex.model_usage_today));

        let mut changed = update_local_snapshots(
            &mut state.stored.snapshots,
            &credentials.node_id,
            "claude",
            &claude_days,
            now,
        );
        changed.extend(update_local_snapshots(
            &mut state.stored.snapshots,
            &credentials.node_id,
            "codex",
            &codex_days,
            now,
        ));
        state.pending_announcements.extend(changed.clone());
        let local_live = ClusterLiveStatus {
            node_id: credentials.node_id.clone(),
            node_name: credentials.node_name.clone(),
            observed_at: now as f64,
            claude: ClusterAgentStatus::from_provider(&local.claude, now),
            codex: ClusterAgentStatus::from_provider(&local.codex, now),
        };
        state
            .live_statuses
            .insert(credentials.node_id.clone(), local_live);
        upsert_node(
            &mut state.stored.nodes,
            ClusterNodeRecord {
                node_id: credentials.node_id.clone(),
                name: credentials.node_name,
                endpoint: None,
                last_seen_at: Some(now as f64),
                last_sync_at: None,
            },
        );
        if !changed.is_empty() {
            let _ = self.save_locked(&state);
        }

        let live: Vec<ClusterLiveStatus> = state.live_statuses.values().cloned().collect();
        let mut result = local.clone();
        result.claude = aggregate_provider(
            "claude",
            &today,
            &state.stored.snapshots,
            live.iter()
                .map(|status| (status.observed_at, &status.claude)),
            now,
        );
        result.codex = aggregate_provider(
            "codex",
            &today,
            &state.stored.snapshots,
            live.iter()
                .map(|status| (status.observed_at, &status.codex)),
            now,
        );
        result.usage_fetched_at = [
            result.claude.provider_usage_fetched_at,
            result.codex.provider_usage_fetched_at,
        ]
        .into_iter()
        .flatten()
        .max();
        let mut node_ids: std::collections::HashSet<String> = state
            .stored
            .nodes
            .iter()
            .map(|node| node.node_id.clone())
            .collect();
        node_ids.extend(
            state
                .stored
                .snapshots
                .iter()
                .map(|snapshot| snapshot.key.origin_node_id.clone()),
        );
        let online_ids: std::collections::HashSet<&str> = live
            .iter()
            .filter(|status| now as f64 - status.observed_at < ONLINE_SECONDS as f64)
            .map(|status| status.node_id.as_str())
            .collect();
        result.cluster = Some(Cluster {
            enabled: true,
            node_count: u32::try_from(node_ids.len().max(1)).unwrap_or(u32::MAX),
            online_count: u32::try_from(online_ids.len().max(1)).unwrap_or(u32::MAX),
            last_synced_at: state
                .stored
                .nodes
                .iter()
                .filter_map(|node| node.last_sync_at)
                .map(|value| value as i64)
                .max(),
        });
        result
    }

    pub fn provider_days(&self, provider: &str, fallback: &History) -> DayTotals {
        let state = self.lock();
        if !state.stored.credentials.clustered() {
            return fallback.provider_days(provider);
        }
        let mut days = DayTotals::new();
        for snapshot in &state.stored.snapshots {
            if snapshot.key.provider != provider {
                continue;
            }
            let day = days.entry(snapshot.key.day.clone()).or_default();
            for (model, tokens) in &snapshot.models {
                if *tokens > 0 {
                    *day.entry(model.clone()).or_insert(0) += *tokens as u64;
                }
            }
        }
        days
    }

    pub fn today(&self) -> chrono::NaiveDate {
        let now = Utc::now();
        self.bucket_timezone()
            .map(|timezone| now.with_timezone(&timezone).date_naive())
            .unwrap_or_else(|| Local::now().date_naive())
    }
}

impl ClusterAgentStatus {
    fn from_provider(provider: &ProviderStatus, now: i64) -> Self {
        let window = |percent: Option<f64>, reset_minutes: Option<i64>| ClusterUsageWindow {
            percent,
            reset_minutes,
            reset_at: reset_minutes.map(|minutes| (now + minutes.saturating_mul(60)) as f64),
        };
        Self {
            state: provider.status.clone(),
            tokens_today: i64::try_from(provider.tokens_today).unwrap_or(i64::MAX),
            model_usage_today: provider
                .model_usage_today
                .iter()
                .map(|usage| ClusterModelUsage {
                    model: usage.model.clone(),
                    tokens: i64::try_from(usage.tokens).unwrap_or(i64::MAX),
                })
                .collect(),
            primary: window(provider.primary_pct, provider.primary_reset_min),
            weekly: window(provider.weekly_pct, provider.weekly_reset_min),
            needs_input: provider.needs_input,
            error: provider.error.clone(),
            usage_fetched_at: provider.provider_usage_fetched_at.map(|value| value as f64),
            usage_cached: provider.provider_usage_cached,
        }
    }

    fn into_provider(mut self, now: i64) -> ProviderStatus {
        discard_expired(&mut self.primary, now);
        discard_expired(&mut self.weekly, now);
        let models = self
            .model_usage_today
            .into_iter()
            .filter(|usage| usage.tokens > 0)
            .map(|usage| ModelUsage {
                model: usage.model,
                tokens: usage.tokens as u64,
            })
            .collect();
        ProviderStatus {
            status: if self.state.is_empty() {
                "offline".to_string()
            } else {
                self.state
            },
            tokens_today: self.tokens_today.max(0) as u64,
            model_usage_today: models,
            primary_pct: self.primary.percent,
            primary_reset_min: self.primary.reset_minutes,
            weekly_pct: self.weekly.percent,
            weekly_reset_min: self.weekly.reset_minutes,
            needs_input: self.needs_input,
            error: self.error,
            provider_usage_fetched_at: self.usage_fetched_at.map(|value| value as i64),
            provider_usage_cached: self.usage_cached,
        }
    }
}

fn models_to_map(models: &[ModelUsage]) -> HashMap<String, u64> {
    models
        .iter()
        .filter(|usage| usage.tokens > 0)
        .map(|usage| (usage.model.clone(), usage.tokens))
        .collect()
}

fn update_local_snapshots(
    snapshots: &mut Vec<ClusterUsageSnapshot>,
    node_id: &str,
    provider: &str,
    days: &DayTotals,
    now: i64,
) -> Vec<ClusterSnapshotDescriptor> {
    let mut changed = Vec::new();
    for (day, models) in days {
        let models: BTreeMap<String, i64> = models
            .iter()
            .filter(|(_, tokens)| **tokens > 0)
            .map(|(model, tokens)| (model.clone(), i64::try_from(*tokens).unwrap_or(i64::MAX)))
            .collect();
        if models.is_empty() {
            continue;
        }
        let key = ClusterSnapshotKey {
            origin_node_id: node_id.to_string(),
            day: day.clone(),
            provider: provider.to_string(),
        };
        if let Some(snapshot) = snapshots.iter_mut().find(|snapshot| snapshot.key == key) {
            if snapshot.models == models {
                continue;
            }
            snapshot.revision = snapshot.revision.saturating_add(1);
            snapshot.observed_at = now as f64;
            snapshot.models = models;
            changed.push(snapshot.descriptor());
        } else {
            let snapshot = ClusterUsageSnapshot {
                key,
                revision: 1,
                observed_at: now as f64,
                models,
            };
            changed.push(snapshot.descriptor());
            snapshots.push(snapshot);
        }
    }
    changed
}

fn aggregate_provider<'a>(
    provider: &str,
    today: &str,
    snapshots: &[ClusterUsageSnapshot],
    statuses: impl Iterator<Item = (f64, &'a ClusterAgentStatus)>,
    now: i64,
) -> ProviderStatus {
    let statuses: Vec<(f64, ClusterAgentStatus)> = statuses
        .map(|(observed, status)| (observed, status.clone()))
        .collect();
    let mut models: HashMap<String, u64> = HashMap::new();
    for snapshot in snapshots {
        if snapshot.key.provider != provider || snapshot.key.day != today {
            continue;
        }
        for (model, tokens) in &snapshot.models {
            if *tokens > 0 {
                *models.entry(model.clone()).or_insert(0) += *tokens as u64;
            }
        }
    }
    let model_usage_today = crate::source::local::sessions::sorted_models(models);
    let tokens_today = model_usage_today.iter().map(|usage| usage.tokens).sum();
    let online: Vec<&ClusterAgentStatus> = statuses
        .iter()
        .filter(|(observed, _)| now as f64 - *observed < ONLINE_SECONDS as f64)
        .map(|(_, status)| status)
        .collect();
    let mut result = preferred_usage_status(&statuses, now)
        .unwrap_or_default()
        .into_provider(now);
    result.tokens_today = tokens_today;
    result.model_usage_today = model_usage_today;
    result.status = if online.iter().any(|status| status.state == "working") {
        "working"
    } else if online.is_empty() {
        "offline"
    } else {
        "idle"
    }
    .to_string();
    result.needs_input = online.iter().any(|status| status.needs_input);
    result
}

fn preferred_usage_status(
    statuses: &[(f64, ClusterAgentStatus)],
    now: i64,
) -> Option<ClusterAgentStatus> {
    let normalized: Vec<(f64, ClusterAgentStatus)> = statuses
        .iter()
        .map(|(observed, status)| {
            let mut status = status.clone();
            discard_expired(&mut status.primary, now);
            discard_expired(&mut status.weekly, now);
            (*observed, status)
        })
        .collect();
    let with_usage: Vec<&(f64, ClusterAgentStatus)> = normalized
        .iter()
        .filter(|(_, status)| status.primary.percent.is_some() || status.weekly.percent.is_some())
        .collect();
    let candidates: Vec<&(f64, ClusterAgentStatus)> = if with_usage.is_empty() {
        normalized.iter().collect()
    } else {
        with_usage
    };
    let newest = candidates
        .iter()
        .map(|(observed, status)| status.usage_fetched_at.unwrap_or(*observed))
        .max_by(f64::total_cmp)?;
    let recent: Vec<&(f64, ClusterAgentStatus)> = candidates
        .into_iter()
        .filter(|(observed, status)| {
            newest - status.usage_fetched_at.unwrap_or(*observed)
                <= USAGE_ERROR_TOLERANCE_SECONDS as f64
        })
        .collect();
    let error_free: Vec<&(f64, ClusterAgentStatus)> = recent
        .iter()
        .copied()
        .filter(|(_, status)| status.error.is_none())
        .collect();
    let preferred = if error_free.is_empty() {
        recent
    } else {
        error_free
    };
    preferred
        .into_iter()
        .max_by(|(left_observed, left), (right_observed, right)| {
            left.usage_fetched_at
                .unwrap_or(*left_observed)
                .total_cmp(&right.usage_fetched_at.unwrap_or(*right_observed))
        })
        .map(|(_, status)| status.clone())
}

fn discard_expired(window: &mut ClusterUsageWindow, now: i64) {
    if window.reset_at.is_some_and(|reset| reset <= now as f64) {
        window.percent = None;
        window.reset_minutes = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::AtomicU32;

    use crate::source::local::hooks::{self, HookRegistry, SharedStatus};

    fn service(name: &str) -> Arc<ClusterService> {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "elink-tui-cluster-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        Arc::new(
            ClusterService::load(root.join("cluster.json"), Some(name))
                .expect("load cluster state"),
        )
    }

    fn provider(model: &str, tokens: u64, percent: f64, fetched_at: i64) -> ProviderStatus {
        ProviderStatus {
            status: "working".to_string(),
            tokens_today: tokens,
            model_usage_today: vec![ModelUsage {
                model: model.to_string(),
                tokens,
            }],
            primary_pct: Some(percent),
            primary_reset_min: Some(60),
            weekly_pct: Some(percent + 1.0),
            weekly_reset_min: Some(1440),
            provider_usage_fetched_at: Some(fetched_at),
            ..ProviderStatus::default()
        }
    }

    fn snapshot(model: &str, tokens: u64, percent: f64, fetched_at: i64) -> Snapshot {
        Snapshot {
            schema_version: 1,
            generated_at: Some(epoch_now()),
            usage_fetched_at: Some(fetched_at),
            cluster: None,
            claude: provider(model, tokens, percent, fetched_at),
            codex: ProviderStatus::default(),
        }
    }

    #[test]
    fn crypto_roundtrip_and_signature_reject_tampering() {
        let key = [7u8; 32];
        let value = ClusterPullRequest {
            keys: vec![ClusterSnapshotKey {
                origin_node_id: "node-a".to_string(),
                day: "2026-07-20".to_string(),
                provider: "claude".to_string(),
            }],
        };
        let body = seal(&value, &key, "node-a").expect("seal");
        let (sender, opened): (String, ClusterPullRequest) = open(&body, &key).expect("open");
        assert_eq!(sender, "node-a");
        assert_eq!(opened.keys, value.keys);

        let headers = signed_headers(
            "POST",
            "/v2/cluster/pull",
            &body,
            "node-a",
            &key,
            1_000,
            "nonce",
        )
        .unwrap()
        .into_iter()
        .map(|(name, value)| (name.to_ascii_lowercase(), value))
        .collect();
        let request = ClusterHttpRequest {
            method: "POST".to_string(),
            path: "/v2/cluster/pull".to_string(),
            headers,
            body: body.clone(),
            peer_host: "127.0.0.1".to_string(),
            local_port: 8765,
        };
        assert!(verify_headers(&request, &key, 1_000).is_ok());
        let mut tampered = request;
        tampered.body.push(0);
        assert!(verify_headers(&tampered, &key, 1_000).is_err());
    }

    #[test]
    fn cryptokit_fixed_vectors_match_rust_crypto() {
        let key = [7u8; 32];
        let headers = signed_headers(
            "POST",
            "/v2/cluster/pull",
            b"hello",
            "node-a",
            &key,
            1_000,
            "nonce",
        )
        .unwrap();
        assert_eq!(
            headers["X-Elink-Signature"],
            "mcxRJ9wAUnQT93xWUr5wrjXZ0l1BtJnia8T5B6aL+HM="
        );

        // Generated by mac-app's CryptoKit with nonce bytes 0...11.
        let combined = BASE64_STANDARD
            .decode("AAECAwQFBgcICQoLY4RbzpEFoU+fpL6e1sKCIAD4C/br")
            .unwrap();
        let nonce: [u8; 12] = combined[..12].try_into().unwrap();
        let mut encrypted = combined[12..].to_vec();
        let unbound = aead::UnboundKey::new(
            &aead::AES_256_GCM,
            &derived_key(&key, "encryption").unwrap(),
        )
        .unwrap();
        let plaintext = aead::LessSafeKey::new(unbound)
            .open_in_place(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(b"node-a"),
                &mut encrypted,
            )
            .unwrap();
        assert_eq!(plaintext, b"hello");
    }

    #[test]
    fn pairing_key_agreement_matches_and_proof_hides_code() {
        let rng = SystemRandom::new();
        let first = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).unwrap();
        let first_public = first.compute_public_key().unwrap().as_ref().to_vec();
        let second = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).unwrap();
        let second_public = second.compute_public_key().unwrap().as_ref().to_vec();
        let code = "ABCD-EFGH-JKMP-QRST";
        let normalized = normalize_pairing_code(code).unwrap();
        let first_key = pairing_key(first, &second_public, &normalized).unwrap();
        let second_key = pairing_key(second, &first_public, &normalized).unwrap();
        assert_eq!(first_key, second_key);
        let request = ClusterJoinRequest {
            proof: pairing_proof(&normalized, &first_public, "node-a"),
            client_node_id: "node-a".to_string(),
            client_name: "Linux".to_string(),
            client_public_key: BASE64_STANDARD.encode(first_public),
        };
        let wire = serde_json::to_string(&request).unwrap();
        assert!(!wire.contains(&normalized));
    }

    #[test]
    fn state_is_private_and_leaving_preserves_local_snapshots() {
        let service = service("node-a");
        service.create_cluster().unwrap();
        let local = snapshot("sonnet", 100, 10.0, epoch_now());
        let aggregate = service.aggregate(&local, None);
        assert_eq!(aggregate.claude.tokens_today, 100);
        let path = service.path.clone();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        service.leave_cluster().unwrap();
        let state = service.lock();
        assert!(!state.stored.credentials.clustered());
        assert!(state
            .stored
            .snapshots
            .iter()
            .all(|snapshot| snapshot.key.origin_node_id == state.stored.credentials.node_id));
    }

    #[test]
    fn pairing_manifest_pull_and_aggregation_interoperate_over_http() {
        let host = service("host");
        host.create_cluster().unwrap();
        let host_snapshot = snapshot("sonnet", 100, 25.0, epoch_now());
        host.aggregate(&host_snapshot, None);
        let code = host.start_pairing().unwrap();
        let listener = hooks::spawn_listener(
            "127.0.0.1:0",
            Arc::new(HookRegistry::default()),
            SharedStatus::default(),
            Arc::clone(&host),
        )
        .expect("bind cluster listener");
        let endpoint = format!("http://{}", listener.local_addr());

        let joiner = service("joiner");
        joiner.join_cluster(&endpoint, &code).expect("join cluster");
        joiner
            .sync_peer(&network_agent(Duration::from_secs(5)), &endpoint)
            .expect("sync peer");
        let joined_snapshot = snapshot("opus", 50, 40.0, epoch_now() + 1);
        let aggregate = joiner.aggregate(&joined_snapshot, None);

        assert_eq!(host.view().cluster_id, joiner.view().cluster_id);
        assert_eq!(aggregate.claude.tokens_today, 150);
        assert_eq!(aggregate.claude.primary_pct, Some(40.0));
        assert_eq!(
            aggregate.cluster.as_ref().map(|value| value.node_count),
            Some(2)
        );
    }

    #[test]
    fn newer_remote_revision_replaces_but_older_cannot_overwrite() {
        let service = service("node-a");
        service.create_cluster().unwrap();
        let generation = service.lock().generation;
        let remote = |revision, tokens| ClusterUsageSnapshot {
            key: ClusterSnapshotKey {
                origin_node_id: "node-b".to_string(),
                day: "2026-07-20".to_string(),
                provider: "claude".to_string(),
            },
            revision,
            observed_at: 1_783_000_000.0,
            models: BTreeMap::from([("opus".to_string(), tokens)]),
        };
        service
            .merge_snapshots(vec![remote(2, 200)], generation)
            .unwrap();
        service
            .merge_snapshots(vec![remote(1, 999)], generation)
            .unwrap();
        let state = service.lock();
        let snapshot = state
            .stored
            .snapshots
            .iter()
            .find(|snapshot| snapshot.key.origin_node_id == "node-b")
            .unwrap();
        assert_eq!(snapshot.models["opus"], 200);
    }
}
