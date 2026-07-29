//! STUN binding probe used to classify the local egress NAT.
//!
//! The judgement comes from the tunnel post-mortem: when the local and external
//! ports match, the egress preserves source ports and this host therefore sits
//! in the port-contention pool; when they differ, the NAT (or a local TUN proxy)
//! rewrites the source port and the host never joins the contention. Neither
//! result is "healthy" — port preservation is the precondition for contention,
//! not a sign of good health.

use std::net::UdpSocket;
use std::time::Duration;

const MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];
const BINDING_REQUEST: [u8; 2] = [0x00, 0x01];
const BINDING_SUCCESS: [u8; 2] = [0x01, 0x01];
const XOR_MAPPED_ADDRESS: u16 = 0x0020;
const FAMILY_IPV4: u8 = 0x01;

pub const DEFAULT_SERVERS: [&str; 3] = [
    "stun.miwifi.com:3478",
    "stun.l.google.com:3478",
    "stun.cloudflare.com:3478",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StunObservation {
    pub local_port: u16,
    pub external_address: std::net::Ipv4Addr,
    pub external_port: u16,
}

impl StunObservation {
    pub fn port_preserved(&self) -> bool {
        self.local_port == self.external_port
    }

    pub fn external_endpoint(&self) -> String {
        format!("{}:{}", self.external_address, self.external_port)
    }
}

pub fn request(transaction_id: &[u8; 12]) -> [u8; 20] {
    let mut message = [0u8; 20];
    message[0..2].copy_from_slice(&BINDING_REQUEST);
    // No attributes, so the declared length stays zero.
    message[4..8].copy_from_slice(&MAGIC_COOKIE);
    message[8..20].copy_from_slice(transaction_id);
    message
}

/// Parses XOR-MAPPED-ADDRESS only. Replies whose transaction ID does not match
/// are discarded so unrelated UDP traffic on this socket cannot be mistaken for
/// a response.
pub fn parse_binding(data: &[u8], transaction_id: &[u8; 12]) -> Option<(std::net::Ipv4Addr, u16)> {
    if data.len() < 20
        || data[0..2] != BINDING_SUCCESS
        || data[4..8] != MAGIC_COOKIE
        || &data[8..20] != transaction_id.as_slice()
    {
        return None;
    }
    let declared = u16::from_be_bytes([data[2], data[3]]) as usize;
    let end = (20 + declared).min(data.len());
    let mut offset = 20;
    while offset + 4 <= end {
        let kind = u16::from_be_bytes([data[offset], data[offset + 1]]);
        let length = u16::from_be_bytes([data[offset + 2], data[offset + 3]]) as usize;
        let value = offset + 4;
        if value + length > end {
            return None;
        }
        if kind == XOR_MAPPED_ADDRESS && length >= 8 && data[value + 1] == FAMILY_IPV4 {
            let port = u16::from_be_bytes([data[value + 2], data[value + 3]]) ^ 0x2112;
            let mut octets = [0u8; 4];
            for (index, octet) in octets.iter_mut().enumerate() {
                *octet = data[value + 4 + index] ^ MAGIC_COOKIE[index];
            }
            return Some((std::net::Ipv4Addr::from(octets), port));
        }
        // Attribute values are padded to a four-byte boundary.
        offset = value + length + ((4 - length % 4) % 4);
    }
    None
}

/// Sends one binding request and reads back the reflexive address. Any failure
/// yields `None`; the caller degrades explicitly once every server has failed.
pub fn probe(server: &str, timeout: Duration) -> Option<StunObservation> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.set_read_timeout(Some(timeout)).ok()?;
    let transaction_id = random_transaction_id();
    socket.send_to(&request(&transaction_id), server).ok()?;
    let local_port = socket.local_addr().ok()?.port();
    let mut buffer = [0u8; 1024];
    let (read, _) = socket.recv_from(&mut buffer).ok()?;
    let (external_address, external_port) = parse_binding(&buffer[..read], &transaction_id)?;
    Some(StunObservation {
        local_port,
        external_address,
        external_port,
    })
}

/// Transaction IDs only need to be unpredictable enough to reject stray packets
/// on this socket; they are not a security boundary.
fn random_transaction_id() -> [u8; 12] {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut id = [0u8; 12];
    for chunk in id.chunks_mut(8) {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_usize(chunk.as_ptr() as usize);
        let bytes = hasher.finish().to_ne_bytes();
        let take = chunk.len().min(bytes.len());
        chunk[..take].copy_from_slice(&bytes[..take]);
    }
    id
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    const TRANSACTION_ID: [u8; 12] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    /// 223.95.78.14:4252 is the real egress DS925 landed on after the port
    /// change. Bytes are XORed by hand per RFC 5389 so the test does not simply
    /// restate the implementation.
    fn real_world_response(transaction_id: &[u8; 12]) -> Vec<u8> {
        let mut data = vec![0x01, 0x01, 0x00, 0x0C];
        data.extend_from_slice(&MAGIC_COOKIE);
        data.extend_from_slice(transaction_id);
        data.extend_from_slice(&[0x00, 0x20, 0x00, 0x08]);
        data.extend_from_slice(&[0x00, 0x01, 0x31, 0x8E]);
        data.extend_from_slice(&[0xFE, 0x4D, 0xEA, 0x4C]);
        data
    }

    #[test]
    fn request_is_a_well_formed_binding_request() {
        let message = request(&TRANSACTION_ID);
        assert_eq!(&message[0..4], &[0x00, 0x01, 0x00, 0x00]);
        assert_eq!(&message[4..8], &MAGIC_COOKIE);
        assert_eq!(&message[8..20], &TRANSACTION_ID);
    }

    #[test]
    fn parses_xor_mapped_address() {
        let parsed = parse_binding(&real_world_response(&TRANSACTION_ID), &TRANSACTION_ID);
        assert_eq!(parsed, Some((Ipv4Addr::new(223, 95, 78, 14), 4252)));
    }

    #[test]
    fn rejects_mismatched_transaction_and_non_success_messages() {
        let other = [99u8; 12];
        assert!(parse_binding(&real_world_response(&other), &TRANSACTION_ID).is_none());

        let mut error_reply = real_world_response(&TRANSACTION_ID);
        error_reply[1] = 0x11; // Binding Error Response
        assert!(parse_binding(&error_reply, &TRANSACTION_ID).is_none());

        let mut wrong_cookie = real_world_response(&TRANSACTION_ID);
        wrong_cookie[4] = 0x00;
        assert!(parse_binding(&wrong_cookie, &TRANSACTION_ID).is_none());

        assert!(parse_binding(&[0x01, 0x01], &TRANSACTION_ID).is_none());
    }

    /// Real servers put SOFTWARE and friends first; parsing must skip them and
    /// honour the four-byte padding.
    #[test]
    fn skips_preceding_attributes_with_padding() {
        let mut data = vec![0x01, 0x01, 0x00, 0x18];
        data.extend_from_slice(&MAGIC_COOKIE);
        data.extend_from_slice(&TRANSACTION_ID);
        data.extend_from_slice(&[0x80, 0x22, 0x00, 0x05]);
        data.extend_from_slice(&[0x65, 0x6C, 0x69, 0x6E, 0x6B, 0x00, 0x00, 0x00]);
        data.extend_from_slice(&[0x00, 0x20, 0x00, 0x08]);
        data.extend_from_slice(&[0x00, 0x01, 0x31, 0x8E]);
        data.extend_from_slice(&[0xFE, 0x4D, 0xEA, 0x4C]);

        let parsed = parse_binding(&data, &TRANSACTION_ID);
        assert_eq!(parsed, Some((Ipv4Addr::new(223, 95, 78, 14), 4252)));
    }

    #[test]
    fn truncated_attribute_is_rejected() {
        let mut data = vec![0x01, 0x01, 0x00, 0x0C];
        data.extend_from_slice(&MAGIC_COOKIE);
        data.extend_from_slice(&TRANSACTION_ID);
        data.extend_from_slice(&[0x00, 0x20, 0x00, 0x08]);
        data.extend_from_slice(&[0x00, 0x01, 0x31, 0x8E]);
        assert!(parse_binding(&data, &TRANSACTION_ID).is_none());
    }

    #[test]
    fn port_preservation_judgement() {
        let preserving = StunObservation {
            local_port: 58682,
            external_address: Ipv4Addr::new(223, 95, 78, 14),
            external_port: 58682,
        };
        assert!(preserving.port_preserved());
        assert_eq!(preserving.external_endpoint(), "223.95.78.14:58682");

        // Mini-M4 behind Shadowrocket's TUN stack: the source port is rewritten.
        let rewriting = StunObservation {
            local_port: 65080,
            external_address: Ipv4Addr::new(223, 95, 78, 14),
            external_port: 65264,
        };
        assert!(!rewriting.port_preserved());
    }

    #[test]
    fn transaction_ids_differ_between_calls() {
        assert_ne!(random_transaction_id(), random_transaction_id());
    }
}
