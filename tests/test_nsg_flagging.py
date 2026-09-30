"""Offline tests for the NSG auditor in 01_parse_blackbox.py."""

import importlib.util
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
NSG = REPO_ROOT / "data" / "blackbox" / "nsg_export_ground_station.json"

spec = importlib.util.spec_from_file_location(
    "parse_blackbox", REPO_ROOT / "day2" / "src" / "01_parse_blackbox.py"
)
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)


def test_fixture_flags_only_the_planted_rule():
    nsg = json.loads(NSG.read_text(encoding="utf-8"))
    flagged = pb.flag_nsg_rules(nsg)
    names = {f["name"] for f in flagged}
    assert names == {"AllowAllInbound"}, f"unexpected flags: {names}"
    assert flagged[0]["severity"] == "critical"


def test_legitimate_rules_not_flagged():
    nsg = json.loads(NSG.read_text(encoding="utf-8"))
    flagged = {f["name"] for f in pb.flag_nsg_rules(nsg)}
    assert "AllowOrbitnetTelemetry" not in flagged
    assert "AllowPartnerRelay" not in flagged


def test_deny_rules_and_outbound_ignored():
    synthetic = {
        "securityRules": [
            {"name": "DenyIn", "direction": "Inbound", "access": "Deny",
             "sourceAddressPrefix": "*", "destinationAddressPrefix": "*",
             "destinationPortRange": "*"},
            {"name": "AllowOut", "direction": "Outbound", "access": "Allow",
             "sourceAddressPrefix": "*", "destinationAddressPrefix": "*",
             "destinationPortRange": "*"},
        ]
    }
    assert pb.flag_nsg_rules(synthetic) == []


def test_wildcard_source_variants_caught():
    for src in ("*", "0.0.0.0/0", "Internet", "Any"):
        rule = {"securityRules": [{"name": "x", "direction": "Inbound",
                "access": "Allow", "sourceAddressPrefix": src,
                "destinationAddressPrefix": "*", "destinationPortRange": "*"}]}
        assert pb.flag_nsg_rules(rule), f"source '{src}' should be flagged"
