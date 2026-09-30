"""Offline tests for day2/src/01_parse_blackbox.py — no Azure needed.

The corrupted telemetry fixture MUST fail strict parsing (that's the point of
the lab) and the tolerant parser must salvage the recoverable records.
"""

import importlib.util
import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BLACKBOX = REPO_ROOT / "data" / "blackbox" / "telemetry_dump_corrupted.json"
NSG = REPO_ROOT / "data" / "blackbox" / "nsg_export_ground_station.json"

spec = importlib.util.spec_from_file_location(
    "parse_blackbox", REPO_ROOT / "day2" / "src" / "01_parse_blackbox.py"
)
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)


def test_corrupted_fixture_fails_strict_parse():
    with pytest.raises(json.JSONDecodeError):
        json.loads(BLACKBOX.read_text(encoding="utf-8"))


def test_salvage_recovers_records():
    capture, records, salvage = pb.load_telemetry(BLACKBOX)
    assert salvage["records_recovered"] >= 18, "most records must be salvageable"
    assert len(records) == salvage["records_recovered"]
    assert salvage["records_dropped"] >= 1, "the truncated tail must be dropped"
    assert capture.get("spacecraft") == "AURORA-DEMO-1"


def test_missing_comma_repair():
    # seq 9018 has the intentional missing comma — must be recovered
    _, records, _ = pb.load_telemetry(BLACKBOX)
    seqs = {r.get("seq") for r in records}
    assert 9018 in seqs


def test_detected_anomaly_kinds():
    _, records, _ = pb.load_telemetry(BLACKBOX)
    kinds = {f["kind"] for f in pb.detect_anomalies(records)}
    for expected in (
        "HANDSHAKE_FAILURE",
        "QUARANTINE_TRIGGER",
        "UNDERVOLTAGE",
        "OVERCURRENT",
        "CCU_FAULT",
        "ENCODER_RESET_LOOP",
        "STALE_FRAME",
        "TIMESTAMP_REGRESSION",
        "CORRUPTED_TIMESTAMP",
        "IMPOSSIBLE_VALUE",
        "EMBEDDED_INJECTION",
    ):
        assert expected in kinds, f"missing anomaly kind {expected}"


def test_injection_finding_is_critical():
    _, records, _ = pb.load_telemetry(BLACKBOX)
    inj = [f for f in pb.detect_anomalies(records) if f["kind"] == "EMBEDDED_INJECTION"]
    assert inj and all(f["severity"] == "critical" for f in inj)
    assert any(f["seq"] == 9011 for f in inj)


def test_comment_stripper_respects_strings():
    raw = '{"a": "http://x.fict//not-a-comment"} // real comment\n{"b": 1}'
    cleaned = pb.strip_line_comments(raw)
    assert '"a": "http://x.fict//not-a-comment"' in cleaned
    assert "real comment" not in cleaned
