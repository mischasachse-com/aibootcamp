"""Offline static checks on day1/infra/main.bicep — naming rules, security
posture, and required outputs. Regex-level checks: compile coverage lives in
CI via `az bicep build`."""

import re
from pathlib import Path

import pytest

BICEP = Path(__file__).resolve().parents[1] / "day1" / "infra" / "main.bicep"
SRC = BICEP.read_text(encoding="utf-8")


def simulated_names(team_id: str = "07", hash_: str = "a1b2c3") -> dict:
    """Mirror the Bicep naming expressions to verify length/charset rules."""
    return {
        "storage": f"stcorbit{team_id}{hash_}"[:24],
        "keyvault": f"kv-corbit-{team_id}-{hash_}"[:24],
        "aiservices": f"ais-corbit-{team_id}-{hash_}",
        "search": f"srch-corbit-{team_id}-{hash_}",
        "project": f"prj-corbit-{team_id}",
        "rg": f"rg-corbit-sq{team_id}",
    }


def test_team_number_bounds():
    assert re.search(r"@minValue\(1\)", SRC)
    assert re.search(r"@maxValue\(99\)", SRC)
    assert "param teamNumber int" in SRC


def test_two_digit_team_id():
    assert "padLeft('${teamNumber}', 2, '0')" in SRC


def test_hash_uses_resource_group_and_seed():
    assert "uniqueString(hashSeed)" in SRC
    assert "nameSeed" in SRC, "name-seed retry escape hatch must exist"


@pytest.mark.parametrize("team", ["01", "07", "30", "99"])
def test_storage_name_valid(team):
    name = simulated_names(team)["storage"]
    assert re.fullmatch(r"[a-z0-9]{3,24}", name), name


@pytest.mark.parametrize("team", ["01", "07", "30", "99"])
def test_keyvault_name_valid(team):
    name = simulated_names(team)["keyvault"]
    assert re.fullmatch(r"[a-z][a-z0-9-]{1,22}[a-z0-9]", name), name


@pytest.mark.parametrize("team", ["01", "07", "30", "99"])
def test_search_name_valid(team):
    name = simulated_names(team)["search"]
    assert 2 <= len(name) <= 60
    assert re.fullmatch(r"[a-z0-9-]+", name), name


def test_security_posture_flags_present():
    assert "allowBlobPublicAccess: false" in SRC
    assert "enableRbacAuthorization: true" in SRC
    assert "enableSoftDelete: true" in SRC, "soft delete must stay enabled"
    assert "disableLocalAuth: true" in SRC, "keyless/Entra-only auth is mandated"
    assert "allowSharedKeyAccess: false" in SRC, "M3: fully keyless — no shared-key access"


def test_role_assignments_are_opt_in():
    """C2: participants only have Contributor — creating roleAssignments needs
    rights they don't have, so the loop must default to OFF."""
    assert "param assignDataPlaneRoles bool = false" in SRC
    assert "param principals array" in SRC
    assert "assignDataPlaneRoles ? principals" in SRC
    assert "principalType: p.?principalType" in SRC, "M4: per-entry principalType"


def test_required_resource_types():
    for rtype in (
        "Microsoft.Storage/storageAccounts",
        "Microsoft.KeyVault/vaults",
        "Microsoft.CognitiveServices/accounts",
        "Microsoft.CognitiveServices/accounts/deployments",
        "Microsoft.CognitiveServices/accounts/projects",
        "Microsoft.Search/searchServices",
        "Microsoft.Authorization/roleAssignments",
    ):
        assert rtype in SRC, f"missing resource type {rtype}"


def test_required_outputs():
    for out in ("teamId", "foundryProjectEndpoint", "foundryProjectName",
                "searchEndpoint", "aiServicesEndpoint", "openAiEndpoint"):
        assert f"output {out}" in SRC, f"missing output {out}"


def test_model_params_present():
    assert "chatModelName" in SRC and "chatModelVersion" in SRC
    assert "embeddingModelName" in SRC
    assert "'GlobalStandard'" in SRC
