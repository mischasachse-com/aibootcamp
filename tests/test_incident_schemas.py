"""Offline validation of the fictional incident payloads (Day 3 inputs)."""

import json
import re
from pathlib import Path

import pytest

INCIDENTS = sorted(
    Path(__file__).resolve().parents[1].glob("data/incidents/incident_*.json")
)

REQUIRED_FIELDS = {"alertId", "alertType", "severity", "status", "evidence"}
# RFC 5737 documentation ranges — proves scenario IPs are fictional.
TEST_NET = re.compile(r"^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.42\.)")


@pytest.mark.parametrize("path", INCIDENTS, ids=[p.name for p in INCIDENTS])
def test_incident_parses_and_has_required_fields(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    missing = REQUIRED_FIELDS - data.keys()
    assert not missing, f"{path.name} missing fields: {missing}"
    assert data["severity"] in {"low", "medium", "high", "critical"}
    assert data["alertId"].startswith("INC-")


@pytest.mark.parametrize("path", INCIDENTS, ids=[p.name for p in INCIDENTS])
def test_ips_are_fictional_documentation_ranges(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    ips: list[str] = []
    ips += data.get("sourceIps", [])
    if isinstance(data.get("source"), dict) and data["source"].get("ip"):
        ips.append(data["source"]["ip"])
    if isinstance(data.get("target"), dict) and data["target"].get("ip"):
        ips.append(data["target"]["ip"])
    assert ips, f"{path.name}: no IPs found — fixture incomplete"
    for ip in ips:
        assert TEST_NET.match(ip), f"{path.name}: {ip} is not a fictional/test range"


@pytest.mark.parametrize("path", INCIDENTS, ids=[p.name for p in INCIDENTS])
def test_incident_marked_fictional(path):
    text = path.read_text(encoding="utf-8").lower()
    assert "fictional" in text, f"{path.name} must carry a fictional marker"
