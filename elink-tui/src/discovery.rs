//! mDNS/Bonjour cluster discovery.
//!
//! Publishes this node as `_elink-ai._tcp.local.` and browses for the same
//! service so peers on a LAN find each other without manual endpoints. The TXT
//! record shape matches the mac-app (`version`, `pairproto`, `node`, `pairing`,
//! `cluster`) so a Mac and a Linux terminal discover one another. Resolved
//! peers in the same cluster are handed to [`ClusterService::note_discovered_endpoint`],
//! which the sync worker then reaches over the existing signed/encrypted
//! protocol — discovery only supplies endpoints, never bypasses auth.

use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};

use crate::cluster::ClusterService;

const SERVICE_TYPE: &str = "_elink-ai._tcp.local.";
const PROTOCOL_VERSION: &str = "2";
const PAIRING_PROTOCOL: &str = "3";
/// How often to re-check our own identity and refresh the advertisement.
const REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// Spawns the discovery thread. Failures to start the mDNS daemon are
/// non-fatal: manual `add-peer`/`join` endpoints keep working.
pub fn spawn(cluster: Arc<ClusterService>, port: u16) {
    thread::spawn(move || {
        let Ok(daemon) = ServiceDaemon::new() else {
            return;
        };
        let node_id = cluster.local_node_id();
        let Ok(events) = daemon.browse(SERVICE_TYPE) else {
            let _ = daemon.shutdown();
            return;
        };
        let mut published: Option<(String, String)> = None;
        let mut resolved = HashMap::<String, String>::new();
        let mut own_addresses = local_addresses();
        refresh_registration(&daemon, &cluster, port, &mut published);
        loop {
            match events.recv_timeout(REFRESH_INTERVAL) {
                Ok(ServiceEvent::ServiceResolved(info)) => {
                    if let Some((fullname, endpoint)) =
                        resolved_endpoint(&info, &cluster, &node_id, port, &own_addresses)
                    {
                        let fullname = fullname.to_ascii_lowercase();
                        if let Some(previous) = resolved.insert(fullname, endpoint.clone()) {
                            if previous != endpoint {
                                cluster.forget_discovered_endpoint(&previous);
                            }
                        }
                        cluster.note_discovered_endpoint(&endpoint);
                    }
                }
                Ok(ServiceEvent::ServiceRemoved(_, fullname)) => {
                    if let Some(endpoint) = resolved.remove(&fullname.to_ascii_lowercase()) {
                        if !resolved.values().any(|candidate| candidate == &endpoint) {
                            cluster.forget_discovered_endpoint(&endpoint);
                        }
                    }
                }
                Ok(_) => {}
                Err(_) if events.is_disconnected() => break,
                Err(_) => own_addresses = local_addresses(),
            }
            refresh_registration(&daemon, &cluster, port, &mut published);
        }
        let _ = daemon.shutdown();
    });
}

/// This machine's interface addresses, used to recognise a co-located bridge
/// (e.g. the mac-app on the same host) so discovery never syncs with it.
fn local_addresses() -> HashSet<IpAddr> {
    if_addrs::get_if_addrs()
        .map(|interfaces| interfaces.iter().map(if_addrs::Interface::ip).collect())
        .unwrap_or_default()
}

/// Re-registers the service when the node identity, cluster, or pairing state
/// changed since the last advertisement.
fn refresh_registration(
    daemon: &ServiceDaemon,
    cluster: &ClusterService,
    port: u16,
    published: &mut Option<(String, String)>,
) {
    if !cluster.discovery_enabled() {
        if let Some((_, fullname)) = published.take() {
            let _ = daemon.unregister(&fullname);
        }
        return;
    }
    let view = cluster.view();
    let cluster_id = view.cluster_id.clone().unwrap_or_default();
    let pairing = if view.pairing_code.is_some() {
        "1"
    } else {
        "0"
    };
    let instance = instance_label(&view.node_name, &view.node_id);
    let signature = format!(
        "{}|{}|{}|{}",
        view.node_id, view.node_name, cluster_id, pairing
    );
    if published
        .as_ref()
        .is_some_and(|(current, _)| current == &signature)
    {
        return;
    }

    let mut properties = HashMap::new();
    properties.insert("version".to_string(), PROTOCOL_VERSION.to_string());
    properties.insert("pairproto".to_string(), PAIRING_PROTOCOL.to_string());
    properties.insert("node".to_string(), view.node_id.clone());
    properties.insert("pairing".to_string(), pairing.to_string());
    if !cluster_id.is_empty() {
        properties.insert("cluster".to_string(), cluster_id);
    }

    let host_name = format!("{}.local.", host_label(&view.node_id));
    let Ok(info) = ServiceInfo::new(SERVICE_TYPE, &instance, &host_name, "", port, properties)
    else {
        return;
    };
    let fullname = info.get_fullname().to_string();
    if let Some((_, old_fullname)) = published.as_ref() {
        if old_fullname != &fullname {
            let _ = daemon.unregister(old_fullname);
        }
    }
    if daemon.register(info.enable_addr_auto()).is_ok() {
        *published = Some((signature, fullname));
    }
}

/// A readable, DNS-safe instance label matching the mac-app's use of the node
/// name, with a short node-id suffix to avoid collisions.
fn instance_label(node_name: &str, node_id: &str) -> String {
    let name: String = node_name
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
        .take(40)
        .collect();
    let name = if name.is_empty() { "Linux" } else { &name };
    format!("{name}-{}", host_label(node_id))
}

fn host_label(node_id: &str) -> String {
    let sanitized: String = node_id
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .take(12)
        .collect();
    if sanitized.is_empty() {
        "elink-tui".to_string()
    } else {
        format!("elink-{sanitized}")
    }
}

fn resolved_endpoint(
    info: &ServiceInfo,
    cluster: &ClusterService,
    node_id: &str,
    default_port: u16,
    own_addresses: &HashSet<IpAddr>,
) -> Option<(String, String)> {
    if !cluster.discovery_enabled() {
        return None;
    }
    // Ignore our own advertisement.
    if info.get_property_val_str("node") == Some(node_id) {
        return None;
    }
    // Only sync peers advertising our cluster; a peer with no cluster, or a
    // different one, cannot authenticate against our secret anyway.
    let our_cluster = cluster.view().cluster_id;
    match (our_cluster.as_deref(), info.get_property_val_str("cluster")) {
        (Some(ours), Some(theirs)) if ours == theirs => {}
        _ => return None,
    }
    // Same-machine guard: a co-located bridge (e.g. the mac-app on this host)
    // advertises this machine's own addresses under a different node id.
    // Syncing with it would double-count this machine's usage in the cluster,
    // so skip it. Intentional localhost setups can still use manual `add-peer`.
    if is_same_machine(info.get_addresses(), own_addresses) {
        return None;
    }
    let endpoint = endpoint_for(info, default_port)?;
    Some((info.get_fullname().to_string(), endpoint))
}

/// True when any advertised address is loopback or belongs to this machine, so
/// the peer is really a co-located bridge rather than a remote node.
fn is_same_machine(peer_addresses: &HashSet<IpAddr>, own_addresses: &HashSet<IpAddr>) -> bool {
    peer_addresses
        .iter()
        .any(|address| address.is_loopback() || own_addresses.contains(address))
}

/// Builds an `http://host:port` endpoint from a resolved service, preferring
/// IPv4 and bracketing IPv6.
fn endpoint_for(info: &ServiceInfo, default_port: u16) -> Option<String> {
    let port = if info.get_port() == 0 {
        default_port
    } else {
        info.get_port()
    };
    let addresses = info.get_addresses();
    let ipv4 = addresses.iter().find(|address| address.is_ipv4());
    let address = ipv4.or_else(|| addresses.iter().next())?;
    match address {
        IpAddr::V4(value) => Some(format!("http://{value}:{port}")),
        IpAddr::V6(value) => Some(format!("http://[{value}]:{port}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instance_label_is_dns_safe_and_derived_from_node_id() {
        assert_eq!(
            instance_label("work station", "2f0e-9a1b-CCDD"),
            "workstation-elink-2f0e9a1bCCDD".to_string()
        );
        // Non-alphanumerics dropped, length bounded, empty falls back.
        assert_eq!(host_label("!!!"), "elink-tui".to_string());
        assert!(instance_label(&"a".repeat(100), &"b".repeat(100)).len() <= 59);
    }

    #[test]
    fn same_machine_guard_rejects_local_and_loopback_addresses() {
        let own: HashSet<IpAddr> = ["192.168.1.5".parse().unwrap()].into_iter().collect();
        // A co-located bridge advertising this machine's LAN address.
        let colocated: HashSet<IpAddr> = ["192.168.1.5".parse().unwrap()].into_iter().collect();
        assert!(is_same_machine(&colocated, &own));
        // Loopback is always same-machine, even if not in the interface set.
        let loopback: HashSet<IpAddr> = ["127.0.0.1".parse().unwrap()].into_iter().collect();
        assert!(is_same_machine(&loopback, &own));
        // A genuine remote peer shares no address with us.
        let remote: HashSet<IpAddr> = ["192.168.1.9".parse().unwrap()].into_iter().collect();
        assert!(!is_same_machine(&remote, &own));
    }
}
