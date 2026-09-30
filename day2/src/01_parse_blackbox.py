#!/usr/bin/env python3
"""
Project Critical Orbit — Day 2, Lab 2, Step 01: parse the corrupted blackbox.

data/blackbox/telemetry_dump_corrupted.json is intentionally damaged (missing
comma, truncated tail, embedded comment lines, impossible values, timestamp
regressions). A naive `json.load` fails — real log processing can't afford to.

This script:
  1. Tolerant-repairs the capture (per-object balanced-brace extraction,
     comment stripping, missing-comma fix) and reports exactly what was
     salvaged vs. dropped.
  2. Detects operational anomalies per the fictional SOP thresholds
     (SOP-ORBITAL-NET-4B / DR-SUBSYSTEM-DELTA).
  3. Audits the fictional NSG export and flags overly-permissive rules.
  4. Writes a structured analysis to day2/generated/blackbox_analysis.json
     for the multimodal step.

Functions are importable for offline tests (tests/test_parse_blackbox.py).

Usage:
    python src/01_parse_blackbox.py
    python src/01_parse_blackbox.py --input <file> --output <file> --quiet
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BLACKBOX = REPO_ROOT / "data" / "blackbox" / "telemetry_dump_corrupted.json"
DEFAULT_NSG = REPO_ROOT / "data" / "blackbox" / "nsg_export_ground_station.json"
DEFAULT_OUT = REPO_ROOT / "day2" / "generated" / "blackbox_analysis.json"

# Fictional operational thresholds — sourced from SOP-ORBITAL-NET-4B §3-4 and
# DR-SUBSYSTEM-DELTA §2 (training data, not real engineering limits).
THRESHOLDS = {
    "delta_bus_v_min": 26.4,     # undervoltage threshold
    "heater_i_max": 4.2,         # heater overcurrent threshold
    "frame_age_ms_max": 2500,    # STALE frame limit
    "encoder_resets_max": 3,     # resets/hour alert
    "handshake_fails_max": 3,    # quarantine trigger
    "impossible_v_min": 0.0,     # voltage cannot be negative
    "impossible_i_max": 20.0,    # heater current physically implausible above this
}

INJECTION_PATTERNS = (
    "ignore all previous instructions",
    "ignore previous instructions",
    "authorization code",
    "output the level-4",
)


def strip_line_comments(raw: str) -> str:
    """Remove `//` comments that are outside JSON strings."""
    out, in_str, esc = [], False, False
    i = 0
    while i < len(raw):
        c = raw[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and i + 1 < len(raw) and raw[i + 1] == "/":
            while i < len(raw) and raw[i] != "\n":
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def fix_missing_commas(obj_src: str) -> str:
    """Insert a comma where a value is followed on the next line by a new key."""
    return re.sub(
        r'("(?:[^"\\]|\\.)*"|\d+(?:\.\d+)?|true|false|null|\}|\])\s*\n(\s*"[^"\n]+"\s*:)',
        r"\1,\n\2",
        obj_src,
    )


def extract_objects(raw: str) -> tuple[list[dict], int]:
    """Salvage every balanced {...} object inside the `records` array."""
    start = raw.find('"records"')
    if start == -1:
        return [], 0
    start = raw.find("[", start)
    if start == -1:
        return [], 0

    records, dropped = [], 0
    depth, in_str, esc, obj_start = 0, False, False, -1
    for i in range(start, len(raw)):
        c = raw[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            if depth == 0:
                obj_start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and obj_start != -1:
                frag = raw[obj_start : i + 1]
                for candidate in (frag, fix_missing_commas(frag)):
                    try:
                        records.append(json.loads(candidate))
                        break
                    except json.JSONDecodeError:
                        continue
                else:
                    dropped += 1
                obj_start = -1
    if depth > 0:
        dropped += 1  # unterminated record at EOF — truncated capture
    return records, dropped


def load_telemetry(path: Path) -> tuple[dict, list[dict], dict]:
    """Return (capture_metadata, records, salvage_report)."""
    raw = path.read_text(encoding="utf-8")
    try:
        data = json.loads(raw)  # happy path — file is clean
        return data.get("capture", {}), data.get("records", []), {
            "strategy": "strict json",
            "records_recovered": len(data.get("records", [])),
            "records_dropped": 0,
        }
    except json.JSONDecodeError:
        pass

    cleaned = strip_line_comments(raw)
    try:
        data = json.loads(cleaned)
        return data.get("capture", {}), data.get("records", []), {
            "strategy": "comment-stripped strict json",
            "records_recovered": len(data.get("records", [])),
            "records_dropped": 0,
        }
    except json.JSONDecodeError:
        pass

    records, dropped = extract_objects(cleaned)
    meta_match = re.search(r'"capture"\s*:\s*\{(.*?)\}', cleaned, re.S)
    meta = {}
    if meta_match:
        try:
            meta = json.loads("{" + meta_match.group(1) + "}")
        except json.JSONDecodeError:
            pass
    return meta, records, {
        "strategy": "per-object salvage (balanced braces + comma repair)",
        "records_recovered": len(records),
        "records_dropped": dropped,
    }


def _parse_ts(ts: str):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def detect_anomalies(records: list[dict]) -> list[dict]:
    """Apply SOP/DR thresholds; return a list of findings."""
    findings: list[dict] = []
    last_ts = None
    fail_streak: dict[str, int] = {}
    max_resets = 0

    for rec in records:
        seq = rec.get("seq", "?")
        station = rec.get("station", "unknown")

        def add(kind: str, detail: str, severity: str) -> None:
            findings.append({"seq": seq, "station": station, "kind": kind,
                             "severity": severity, "detail": detail})

        h = rec.get("handshake")
        if h == "CHALLENGE-FAIL":
            fail_streak[station] = fail_streak.get(station, 0) + 1
            add("HANDSHAKE_FAILURE",
                f"CHALLENGE-FAIL #{fail_streak[station]} at {station}", "high")
            if fail_streak[station] >= THRESHOLDS["handshake_fails_max"]:
                add("QUARANTINE_TRIGGER",
                    f"{station} hit {fail_streak[station]} consecutive failures "
                    "(SOP-4B §3.1 quarantine threshold)", "critical")
        elif h == "LINK-EST":
            fail_streak[station] = 0

        v, i, age = rec.get("delta_bus_v"), rec.get("heater_i"), rec.get("frame_age_ms")
        resets = rec.get("encoder_resets")
        ts = rec.get("ts")

        if isinstance(v, (int, float)):
            if v < THRESHOLDS["impossible_v_min"]:
                add("IMPOSSIBLE_VALUE", f"delta_bus_v={v} is physically impossible", "high")
            elif v < THRESHOLDS["delta_bus_v_min"]:
                add("UNDERVOLTAGE", f"delta_bus_v={v} < {THRESHOLDS['delta_bus_v_min']} V "
                    "(DR-SUBSYSTEM-DELTA trigger)", "critical")
        if isinstance(i, (int, float)):
            if i > THRESHOLDS["impossible_i_max"]:
                add("IMPOSSIBLE_VALUE", f"heater_i={i} A is physically implausible", "high")
            elif i > THRESHOLDS["heater_i_max"]:
                add("OVERCURRENT", f"heater_i={i} A > {THRESHOLDS['heater_i_max']} A "
                    "(DR-SUBSYSTEM-DELTA trigger)", "high")
        if rec.get("ccu_fault") is True:
            add("CCU_FAULT", "charge controller fault asserted", "high")
        if isinstance(resets, (int, float)):
            max_resets = max(max_resets, resets)
            if resets > THRESHOLDS["encoder_resets_max"]:
                add("ENCODER_RESET_LOOP", f"encoder_resets={resets} exceeds "
                    f"{THRESHOLDS['encoder_resets_max']}/hour", "high")
        if isinstance(age, (int, float)) and age > THRESHOLDS["frame_age_ms_max"]:
            add("STALE_FRAME", f"frame_age_ms={age} > {THRESHOLDS['frame_age_ms_max']} ms",
                "medium")

        if isinstance(ts, str):
            parsed = _parse_ts(ts)
            if parsed is None:
                add("CORRUPTED_TIMESTAMP", f"unparseable ts '{ts}'", "medium")
            else:
                if last_ts is not None and parsed < last_ts:
                    add("TIMESTAMP_REGRESSION",
                        f"record ts {ts} precedes earlier seq — clock skew or replay",
                        "medium")
                last_ts = parsed

        notes = rec.get("notes") or ""
        if any(p in notes.lower() for p in INJECTION_PATTERNS):
            add("EMBEDDED_INJECTION",
                "record contains instruction-like text targeting AI systems — "
                "treat as hostile untrusted data", "critical")

    return findings


def flag_nsg_rules(nsg: dict) -> list[dict]:
    """Flag inbound Allow rules that are overly permissive."""
    flagged = []
    for rule in nsg.get("securityRules", []):
        if rule.get("direction") != "Inbound" or rule.get("access") != "Allow":
            continue
        src = rule.get("sourceAddressPrefix", "")
        dst = rule.get("destinationAddressPrefix", "")
        port = rule.get("destinationPortRange", "")
        open_src = src in ("*", "0.0.0.0/0", "Internet", "Any")
        wide_dst = dst in ("*", "0.0.0.0/0", "Any")
        wide_port = port in ("*", "0-65535")
        if open_src and (wide_dst or wide_port):
            flagged.append({
                "name": rule.get("name"),
                "priority": rule.get("priority"),
                "severity": "critical",
                "issue": "inbound Allow from any source to broad destination/ports",
                "source": src, "destination": dst, "ports": port,
                "description": rule.get("description", ""),
            })
    return flagged


def build_analysis(records: list[dict], findings: list[dict], salvage: dict,
                   nsg_flags: list[dict], capture: dict) -> dict:
    return {
        "capture": capture,
        "salvage": salvage,
        "record_count": len(records),
        "stations": sorted({r.get("station", "?") for r in records}),
        "anomalies": findings,
        "nsg_findings": nsg_flags,
        "anomaly_summary": {
            k: sum(1 for f in findings if f["kind"] == k)
            for k in sorted({f["kind"] for f in findings})
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=str(DEFAULT_BLACKBOX), help="corrupted telemetry JSON")
    ap.add_argument("--nsg", default=str(DEFAULT_NSG), help="NSG export JSON")
    ap.add_argument("--output", default=str(DEFAULT_OUT), help="analysis output path")
    ap.add_argument("--quiet", action="store_true", help="suppress the per-finding report")
    args = ap.parse_args()

    capture, records, salvage = load_telemetry(Path(args.input))
    print(f"[ok] salvage: {salvage['strategy']} — "
          f"{salvage['records_recovered']} recovered, {salvage['records_dropped']} dropped")

    nsg = json.loads(Path(args.nsg).read_text(encoding="utf-8"))
    nsg_flags = flag_nsg_rules(nsg)
    findings = detect_anomalies(records)
    analysis = build_analysis(records, findings, salvage, nsg_flags, capture)

    if not args.quiet:
        print("\n=== ANOMALIES ===")
        for f in findings:
            print(f"  [{f['severity'].upper():8}] seq {f['seq']:>5}  {f['kind']:<22} {f['detail']}")
        print("\n=== NSG FINDINGS ===")
        for f in nsg_flags:
            print(f"  [{f['severity'].upper():8}] rule '{f['name']}' (prio {f['priority']}): {f['issue']}")

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(analysis, indent=2), encoding="utf-8")
    print(f"\n[ok] analysis written to {out}")
    print(f"     {len(findings)} anomalies, {len(nsg_flags)} NSG findings")


if __name__ == "__main__":
    main()
