//! ICMP echo, used to measure the nebula overlay directly.
//!
//! Written against sockets rather than shelling out to `ping`, whose flags
//! differ between platforms in exactly the dangerous way: `-W` is milliseconds
//! on macOS and seconds on Linux.
//!
//! Two socket types are tried in order, because neither works everywhere:
//!
//! - `SOCK_DGRAM` needs no privilege at all, but on Linux it is gated by
//!   `net.ipv4.ping_group_range`, which several distributions ship as the empty
//!   range `1 0`. That gate has no capability override — even root is refused.
//! - `SOCK_RAW` works there, but requires `CAP_NET_RAW`.
//!
//! So macOS and permissive Linux hosts run unprivileged, and a locked-down
//! Linux host needs only that one capability rather than full root.
//!
//! `SOCK_DGRAM` lets the kernel own the identifier field and rewrite it, while
//! `SOCK_RAW` hands over every ICMP packet on the host including other
//! processes' replies. Matching on the sequence number plus a payload token is
//! correct for both.

use std::io;
use std::mem;
use std::net::Ipv4Addr;
use std::time::{Duration, Instant};

const ECHO_REQUEST: u8 = 8;
const ECHO_REPLY: u8 = 0;
const HEADER_LEN: usize = 8;
/// Marks our own packets so a reply the kernel hands us for some other reason
/// cannot be timed as if it were ours.
const TOKEN: [u8; 8] = *b"elink-ai";

/// Whether this process can open an ICMP socket at all. Callers degrade
/// explicitly instead of reporting every host on the mesh as down.
pub fn available() -> bool {
    IcmpSocket::open().is_ok()
}

/// Sends one echo request and returns the round trip in **microseconds**.
///
/// Microseconds rather than milliseconds because an overlay hop to a host on
/// the same LAN runs well under 1 ms, and truncating that to `0ms` reads as a
/// broken measurement rather than a fast one.
///
/// `None` means no matching reply arrived within `timeout` — which covers a
/// dead host, a dropped tunnel and a firewall that eats ICMP alike. The caller
/// is responsible for telling those apart; this layer only reports the fact.
pub fn ping(address: Ipv4Addr, sequence: u16, timeout: Duration) -> Option<u32> {
    let socket = IcmpSocket::open().ok()?;
    socket.set_read_timeout(timeout).ok()?;
    let request = echo_request(sequence);
    let started = Instant::now();
    socket.send_to(&request, address).ok()?;

    let mut buffer = [0u8; 1500];
    loop {
        // A reply for a different sequence must not consume this attempt's
        // budget entirely, so the deadline is rechecked rather than reset.
        let remaining = timeout.checked_sub(started.elapsed())?;
        if remaining.is_zero() {
            return None;
        }
        socket.set_read_timeout(remaining).ok()?;
        let read = socket.recv(&mut buffer).ok()?;
        if matches_reply(&buffer[..read], sequence) {
            return Some(started.elapsed().as_micros().min(u32::MAX as u128) as u32);
        }
    }
}

/// Builds an echo request with a correct checksum.
///
/// Linux recomputes it for datagram ICMP sockets and macOS does not, so it is
/// computed here for both rather than depending on which one is running.
pub fn echo_request(sequence: u16) -> Vec<u8> {
    let mut packet = vec![0u8; HEADER_LEN + TOKEN.len()];
    packet[0] = ECHO_REQUEST;
    packet[4..6].copy_from_slice(&0u16.to_be_bytes()); // identifier: kernel-owned
    packet[6..8].copy_from_slice(&sequence.to_be_bytes());
    packet[HEADER_LEN..].copy_from_slice(&TOKEN);
    let sum = checksum(&packet);
    packet[2..4].copy_from_slice(&sum.to_be_bytes());
    packet
}

/// Accepts an echo reply for `sequence`, with or without a leading IP header.
///
/// Datagram ICMP sockets strip the IP header on Linux but not always on macOS,
/// and a wrong guess would silently report every host as unreachable, so both
/// framings are tried.
pub fn matches_reply(data: &[u8], sequence: u16) -> bool {
    if is_echo_reply(data, sequence) {
        return true;
    }
    // An IPv4 header is at least 20 bytes and its length lives in the low
    // nibble of the first byte, counted in 32-bit words.
    if data.first().is_some_and(|first| first >> 4 == 4) {
        let header_len = (data[0] & 0x0F) as usize * 4;
        if header_len >= 20 && data.len() > header_len {
            return is_echo_reply(&data[header_len..], sequence);
        }
    }
    false
}

fn is_echo_reply(data: &[u8], sequence: u16) -> bool {
    data.len() >= HEADER_LEN + TOKEN.len()
        && data[0] == ECHO_REPLY
        && u16::from_be_bytes([data[6], data[7]]) == sequence
        && data[HEADER_LEN..HEADER_LEN + TOKEN.len()] == TOKEN
}

/// Standard internet checksum: one's complement of the one's complement sum.
pub fn checksum(data: &[u8]) -> u16 {
    let mut sum = 0u32;
    let (pairs, remainder) = data.as_chunks::<2>();
    for pair in pairs {
        sum += u32::from(u16::from_be_bytes(*pair));
    }
    if let Some(&last) = remainder.first() {
        sum += u32::from(last) << 8;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

struct IcmpSocket(libc::c_int);

impl IcmpSocket {
    /// Prefers the unprivileged socket and falls back to the raw one.
    ///
    /// The fallback is reported under the datagram socket's error, not the raw
    /// one's: `SOCK_RAW` fails with `EPERM` on a host that simply lacks
    /// `CAP_NET_RAW`, which reads as a misconfiguration rather than the real
    /// cause — a `ping_group_range` that excludes this process.
    fn open() -> io::Result<Self> {
        let unprivileged = Self::open_kind(libc::SOCK_DGRAM);
        if unprivileged.is_ok() {
            return unprivileged;
        }
        Self::open_kind(libc::SOCK_RAW).or(unprivileged)
    }

    fn open_kind(kind: libc::c_int) -> io::Result<Self> {
        let descriptor = unsafe { libc::socket(libc::AF_INET, kind, libc::IPPROTO_ICMP) };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(descriptor))
    }

    fn set_read_timeout(&self, timeout: Duration) -> io::Result<()> {
        let limit = libc::timeval {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_usec: timeout.subsec_micros() as libc::suseconds_t,
        };
        let result = unsafe {
            libc::setsockopt(
                self.0,
                libc::SOL_SOCKET,
                libc::SO_RCVTIMEO,
                std::ptr::addr_of!(limit).cast(),
                mem::size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        (result == 0)
            .then_some(())
            .ok_or_else(io::Error::last_os_error)
    }

    fn send_to(&self, packet: &[u8], address: Ipv4Addr) -> io::Result<()> {
        let mut destination: libc::sockaddr_in = unsafe { mem::zeroed() };
        destination.sin_family = libc::AF_INET as libc::sa_family_t;
        destination.sin_addr.s_addr = u32::from_ne_bytes(address.octets());
        let sent = unsafe {
            libc::sendto(
                self.0,
                packet.as_ptr().cast(),
                packet.len(),
                0,
                std::ptr::addr_of!(destination).cast(),
                mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn recv(&self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = unsafe { libc::recv(self.0, buffer.as_mut_ptr().cast(), buffer.len(), 0) };
        if read < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(read as usize)
    }
}

impl Drop for IcmpSocket {
    fn drop(&mut self) {
        unsafe { libc::close(self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A correct echo request checksums to zero when verified in place, which
    /// is what a receiver actually does with it.
    #[test]
    fn request_is_well_formed_and_self_verifying() {
        let packet = echo_request(7);
        assert_eq!(packet[0], ECHO_REQUEST);
        assert_eq!(packet[1], 0);
        assert_eq!(u16::from_be_bytes([packet[6], packet[7]]), 7);
        assert_eq!(&packet[HEADER_LEN..], &TOKEN);
        assert_eq!(checksum(&packet), 0, "checksum must verify in place");
    }

    /// Known-answer check from RFC 1071 so the sum is not merely self-consistent.
    #[test]
    fn checksum_matches_the_rfc_example() {
        let data = [0x00u8, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7];
        assert_eq!(checksum(&data), 0x220d);
    }

    /// An odd-length payload must fold the trailing byte into the high half.
    #[test]
    fn checksum_handles_odd_length() {
        assert_eq!(
            checksum(&[0x12, 0x34, 0x56]),
            checksum(&[0x12, 0x34, 0x56, 0x00])
        );
    }

    fn reply(sequence: u16) -> Vec<u8> {
        let mut packet = echo_request(sequence);
        packet[0] = ECHO_REPLY;
        packet
    }

    #[test]
    fn accepts_a_bare_reply_and_rejects_a_foreign_one() {
        assert!(matches_reply(&reply(3), 3));
        assert!(!matches_reply(&reply(3), 4), "sequence must match");

        let mut untagged = reply(3);
        untagged[HEADER_LEN] = b'x';
        assert!(!matches_reply(&untagged, 3), "payload token must match");

        assert!(
            !matches_reply(&echo_request(3), 3),
            "a request is not a reply"
        );
        assert!(!matches_reply(&[], 3));
    }

    /// macOS may hand back the IP header; guessing wrong would report every
    /// host as unreachable, so the framing is detected rather than assumed.
    #[test]
    fn accepts_a_reply_behind_an_ip_header() {
        let mut framed = vec![0x45, 0x00, 0x00, 0x24];
        framed.extend_from_slice(&[0u8; 16]);
        framed.extend_from_slice(&reply(9));
        assert_eq!(framed[0] & 0x0F, 5, "20-byte header");
        assert!(matches_reply(&framed, 9));
        assert!(!matches_reply(&framed, 8));
    }

    /// A truncated header must not be read past its end.
    #[test]
    fn rejects_a_truncated_ip_header() {
        assert!(!matches_reply(&[0x45, 0x00, 0x00], 1));
        let mut short = vec![0x40];
        short.extend_from_slice(&reply(1));
        assert!(!matches_reply(&short, 1), "header length below the minimum");
    }
}
