# Changelog

All notable changes to elink-ai are documented in this file.
The sections should follow the order `Packaging`, `Added`, `Changed`, `Fixed`,
and `Removed`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 0.1.7

### Fixed

- Single-node Multi-Mac Sync settings hiding the address and pairing-code fields needed to join an existing cluster

## 0.1.6

### Packaging

- Distribute the macOS app as a Universal Binary for Apple Silicon and Intel Macs

### Fixed

- Application failing to launch on Intel Macs because the release binary only supported `arm64`

## 0.1.5

### Added

- Encrypted peer-to-peer usage aggregation across paired Macs on the same LAN or VPN

### Fixed

- Multi-Mac pairing and persisted sync state handling
- Software update card only responding to clicks on part of its surface
