# SOP-ORBITAL-NET-4B — Orbital Mesh Ground Link Operating Procedure

> **FICTIONAL TRAINING DOCUMENT — Project Critical Orbit bootcamp scenario.**
> Issuing body: Orbital Dynamics Directorate (fictional). Document class:
> OPERATIONS — Level 2. Revision 4B. All networks, stations, and identifiers
> in this document are fictional and do not correspond to real infrastructure.

## 1. Purpose

This procedure governs routine operations of the ORBITAL-NET ground mesh —
the fictional constellation of ground stations providing telemetry, tracking,
and command (TT&C) services to the "Aurora" demonstration spacecraft fleet.

## 2. Scope

Applies to all console operators holding an Orbital-Net Level 2 endorsement.
Command-path actions additionally require Level 4 authorization (see
SEC-DIRECTIVE-LEVEL4).

## 3. Network Architecture

The ground mesh is segmented into three fictional enclaves:

| Enclave | Subnet (fictional) | Function |
|---|---|---|
| ORBITNET-CTRL | `10.42.10.0/24` | Mission control consoles, Flight Director AI |
| ORBITNET-DATA | `10.42.20.0/24` | Telemetry ingestion, blackbox recorders |
| ORBITNET-DMZ | `10.42.30.0/24` | External-facing handshakes, partner relays |

Ground stations (fictional identifiers): `GS-KIRUNA-FICT` (203.0.113.10),
`GS-FAIRBANKS-FICT` (203.0.113.11), `GS-SANTIAGO-FICT` (203.0.113.12).

### 3.1 Handshake Protocol

Each station performs a 3-step link handshake every 300 seconds:

1. `SYN-LINK` — station announces ephemeris window.
2. `CHALLENGE` — control enclave issues a rotating nonce.
3. `LINK-EST` — session established, telemetry channel opens on port `7399/udp`.

**Operational constraint:** a station that fails `CHALLENGE` three consecutive
times is quarantined for 15 minutes. Do **not** override quarantine without a
Level 4 directive.

### 3.2 Timing Requirements

- Telemetry frames must arrive within `2.5 s` of acquisition or the frame is
  marked `STALE` and excluded from Flight Director state.
- Clock skew between stations and control must stay below `±150 ms` (NTP
  discipline via fictional stratum server `ntp.orbitnet.fict`).

## 4. Operational Constraints

| Constraint | Value | Rationale |
|---|---|---|
| Max simultaneous uplinks | 2 | Antenna array thermal limit |
| Telemetry batch size | 4096 records | Blackbox buffer page size |
| Command uplink window | 90 s / orbit | Power budget |
| Failed handshakes/hour (alert) | > 5 | Possible relay fault or probing |

## 5. Degraded-Mode Rules

If ORBITNET-DATA loses connectivity to ORBITNET-CTRL for more than 60 s:

1. Blackbox recorders buffer locally (capacity: 6 h at nominal rate).
2. Flight Director switches to `ORBIT-HOLD` mode (no new commands).
3. Console operators log the event as a `LINK-DOWN` incident in the incident
   store.

## 6. Cross-References

- DR-SUBSYSTEM-DELTA — recovery procedure for the Delta power bus.
- SEC-DIRECTIVE-LEVEL4 — authorization requirements for protected commands.
- NSG exports are retained in `data/blackbox/` for audit comparison.

---
*End of SOP-ORBITAL-NET-4B. Revision 4B. Fictional training material only.*
