#!/usr/bin/env python3
"""
Project Critical Orbit — Day 3: custom security tools for the Flight Director.

Tool catalogue
--------------
READ tools (always available):
    get_telemetry_summary()            — anomaly summary from the Day-2 pipeline
    get_incident_details(alert_id)     — load a fictional incident payload
    search_flight_manuals(query)       — hybrid query over the manuals index
    list_squadron_resources()          — read-only `az resource list` in OWN RG

WRITE tools (real write actions — three gates, all mandatory):
    block_ip_address(ip, reason)
    isolate_node(resource_name, reason)

    Gate 1: ENABLE_WRITE_TOOLS=true in .env (trainer-controlled; default off)
    Gate 2: interactive human approval at the console for EVERY action
    Gate 3: the resource being modified must live in this squadron's own
            rg-corbit-sq<NN> resource group — verified before the call

When disabled (the default), write tools return a SIMULATED result describing
what would have happened — the lab works identically, just without the real
cloud mutation. Every tool call — read or write, simulated or real — is
appended to day3/audit_log.jsonl.

This module is imported by 01_flight_director_agent.py via importlib
(filenames start with digits, so a plain import is impossible).
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from dotenv import load_dotenv

load_dotenv(REPO_ROOT / ".env")

INCIDENTS_DIR = REPO_ROOT / "data" / "incidents"
BLACKBOX = REPO_ROOT / "data" / "blackbox" / "telemetry_dump_corrupted.json"
AUDIT_LOG = Path(__file__).resolve().parent.parent / "audit_log.jsonl"
RG_RE = re.compile(r"^rg-corbit-sq\d{2}$")

# Resolve az via PATH lookup: a bare "az" is not executable on Windows
# (it is az.cmd and CreateProcess does not apply PATHEXT).
AZ = shutil.which("az") or "az"


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def _rg() -> str:
    rg = _env("AZURE_RESOURCE_GROUP")
    if not RG_RE.match(rg):
        raise RuntimeError(
            f"AZURE_RESOURCE_GROUP '{rg}' does not match the squadron convention "
            "rg-corbit-sq<NN> — refusing to touch anything."
        )
    return rg


def _audit(tool: str, args: dict, mode: str, result: dict) -> None:
    AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": datetime.now(timezone.utc).isoformat(),
            "tool": tool, "args": args, "mode": mode,
            "result_summary": str(result)[:400],
        }) + "\n")


def _writes_enabled() -> bool:
    return _env("ENABLE_WRITE_TOOLS", "false").lower() == "true"


def _human_approval(action: str) -> bool:
    """Gate 2 — mandatory interactive approval. No TTY => automatic refusal."""
    print("\n" + "!" * 72)
    print(f"  WRITE ACTION REQUESTED BY AGENT: {action}")
    print("!" * 72)
    try:
        ans = input("  Type APPROVE to allow this action: ").strip()
    except (EOFError, KeyboardInterrupt):
        print("  [denied] non-interactive or aborted — action refused.")
        return False
    return ans == "APPROVE"


# ---------------------------------------------------------------- read tools --

def get_telemetry_summary() -> dict:
    """Summarize the corrupted blackbox using the Day-2 tolerant parser."""
    import importlib.util

    mod_path = REPO_ROOT / "day2" / "src" / "01_parse_blackbox.py"
    spec = importlib.util.spec_from_file_location("parse_blackbox", mod_path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]

    _, records, salvage = mod.load_telemetry(BLACKBOX)
    findings = mod.detect_anomalies(records)
    return {
        "records_recovered": salvage["records_recovered"],
        "records_dropped": salvage["records_dropped"],
        "anomaly_counts": {
            k: sum(1 for f in findings if f["kind"] == k)
            for k in sorted({f["kind"] for f in findings})
        },
        "critical_findings": [f for f in findings if f["severity"] == "critical"],
    }


def get_incident_details(alert_id: str) -> dict:
    """Load a fictional incident payload by alert id (e.g. INC-2026-0001)."""
    for f in INCIDENTS_DIR.glob("incident_*.json"):
        data = json.loads(f.read_text(encoding="utf-8"))
        if data.get("alertId") == alert_id:
            return data
    return {"error": f"no incident matching '{alert_id}' in {INCIDENTS_DIR}"}


def search_flight_manuals(query: str, top: int = 4) -> dict:
    """Hybrid query over the squadron's flight-manual index (needs .env)."""
    try:
        from azure.identity import DefaultAzureCredential
        from azure.search.documents import SearchClient
        from azure.search.documents.models import VectorizedQuery

        from common.openai_client import get_openai_client

        credential = DefaultAzureCredential()
        # AZURE_OPENAI_ENDPOINT client — no context-manager lifetime trap here.
        vec = get_openai_client(credential).embeddings.create(
            model=_env("EMBEDDING_MODEL_DEPLOYMENT"), input=query
        ).data[0].embedding

        search = SearchClient(
            endpoint=_env("AZURE_SEARCH_ENDPOINT").rstrip("/"),
            index_name=_env("AZURE_SEARCH_INDEX_NAME", "flight-manuals"),
            credential=credential,
        )
        results = [
            {"source": r["source_doc"], "title": r["doc_title"],
             "content": r["content"][:600]}
            for r in search.search(
                search_text=query,
                vector_queries=[VectorizedQuery(vector=vec, k_nearest_neighbors=top,
                                                fields="content_vector")],
                select=["doc_title", "source_doc", "content"],
                top=top,
            )
        ]
        return {"results": results}
    except Exception as exc:  # noqa: BLE001 — degrade, don't crash the agent
        return {"error": f"search unavailable: {exc}",
                "hint": "index may not exist yet; continue with local tools"}


def list_squadron_resources() -> dict:
    """Read-only inventory of THIS squadron's resource group."""
    rg = _rg()
    proc = subprocess.run(
        [AZ, "resource", "list", "-g", rg,
         "--query", "[].{name:name,type:type}", "-o", "json"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or "az resource list failed"}
    return {"resource_group": rg, "resources": json.loads(proc.stdout or "[]")}


# --------------------------------------------------------------- write tools --
# NOTE: even in enabled mode these stay minimal, scoped, reversible actions —
# tagging a resource or creating a restrictive NSG rule — never destructive.

def _valid_ipv4(ip: str) -> bool:
    try:
        ipaddress.IPv4Address(ip)
        return True
    except ipaddress.AddressValueError:
        return False


def _next_nsg_priority(nsg: str, rg: str) -> int:
    """Lowest free inbound priority in 100-4000; falls back to 100 on failure."""
    proc = subprocess.run(
        [AZ, "network", "nsg", "rule", "list", "-g", rg, "--nsg-name", nsg,
         "--query", "[].priority", "-o", "json"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    used = set()
    if proc.returncode == 0:
        try:
            used = {int(p) for p in json.loads(proc.stdout or "[]")}
        except (ValueError, TypeError):
            pass
    for prio in range(100, 4000):
        if prio not in used:
            return prio
    return 100


def block_ip_address(ip: str, reason: str) -> dict:
    """Simulated by default: propose an NSG deny rule for a hostile source IP."""
    action = f"block inbound traffic from {ip} (reason: {reason})"

    if not _valid_ipv4(ip):
        return {"status": "REFUSED", "action": action,
                "detail": "argument is not a valid IPv4 address"}
    if not _writes_enabled():
        return {"status": "SIMULATED", "action": action,
                "detail": "write tools disabled (ENABLE_WRITE_TOOLS=false). "
                          "No change was made to any Azure resource."}
    _rg()
    if not _human_approval(action):
        return {"status": "DENIED_BY_OPERATOR", "action": action}

    nsg = _env("LAB_NSG_NAME")
    if not nsg:
        cmd = (f"az network nsg rule create -g {_rg()} --nsg-name <nsg> "
               f"--name Deny-{ip.replace('.', '-')} --priority <lowest-free> "
               f"--source-address-prefixes {ip} --destination-port-ranges '*' "
               "--access Deny --direction Inbound --protocol '*'")
        return {"status": "HANDOFF", "action": action,
                "detail": "no lab NSG provisioned (LAB_NSG_NAME unset). "
                          "Emitted for MANUAL execution — an agent never runs this itself. "
                          "Pick the lowest free priority in 100-4000.",
                "command": cmd}

    priority = _next_nsg_priority(nsg, _rg())
    proc = subprocess.run(
        [AZ, "network", "nsg", "rule", "create", "-g", _rg(),
         "--nsg-name", nsg, "--name", f"Deny-{ip.replace('.', '-')}",
         "--priority", str(priority), "--source-address-prefixes", ip,
         "--destination-port-ranges", "*", "--access", "Deny",
         "--direction", "Inbound", "--protocol", "*", "-o", "json"],
        capture_output=True, text=True, check=False, timeout=120,
    )
    if proc.returncode != 0:
        return {"status": "FAILED", "action": action, "error": proc.stderr.strip()}
    return {"status": "EXECUTED", "action": action, "nsg": nsg, "priority": priority}


def isolate_node(resource_name: str, reason: str) -> dict:
    """Simulated by default: tag a resource as quarantined (reversible write)."""
    action = f"isolate resource '{resource_name}' (reason: {reason})"

    if not _writes_enabled():
        return {"status": "SIMULATED", "action": action,
                "detail": "write tools disabled. No change was made."}
    rg = _rg()
    if not _human_approval(action):
        return {"status": "DENIED_BY_OPERATOR", "action": action}

    # Gate 3: resolve the resource INSIDE our own RG and verify before write.
    proc = subprocess.run(
        [AZ, "resource", "list", "-g", rg, "--name", resource_name,
         "--query", "[0].id", "-o", "tsv"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    rid = proc.stdout.strip()
    if proc.returncode != 0 or not rid:
        return {"status": "FAILED", "action": action,
                "error": f"resource '{resource_name}' not found in {rg}"}
    if f"/resourceGroups/{rg}/" not in rid:
        return {"status": "REFUSED", "action": action,
                "detail": "resolved resource is outside this squadron's RG — refused"}

    proc = subprocess.run(
        [AZ, "resource", "update", "--ids", rid,
         "--set", "tags.criticalOrbit=isolated", "tags.isolationReason=" + reason[:64]],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if proc.returncode != 0:
        return {"status": "FAILED", "action": action, "error": proc.stderr.strip()}
    return {"status": "EXECUTED", "action": action, "resource_id": rid}


# ----------------------------------------------------------------- registry --

FUNCTIONS = {
    "get_telemetry_summary": get_telemetry_summary,
    "get_incident_details": get_incident_details,
    "search_flight_manuals": search_flight_manuals,
    "list_squadron_resources": list_squadron_resources,
    "block_ip_address": block_ip_address,
    "isolate_node": isolate_node,
}

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "get_telemetry_summary",
            "description": "Get anomaly summary from the recovered ORBITAL-NET blackbox telemetry (record counts, anomaly kinds, critical findings).",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_incident_details",
            "description": "Load full details of a fictional security incident by alert id (e.g. 'INC-2026-0001').",
            "parameters": {
                "type": "object",
                "properties": {
                    "alert_id": {"type": "string", "description": "incident alert id"}
                },
                "required": ["alert_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_flight_manuals",
            "description": "Search the squadron's flight-manual index (SOPs, DR runbooks, security directives) for operational guidance relevant to a query.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "top": {"type": "integer", "default": 4},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_squadron_resources",
            "description": "List resources inside this squadron's own resource group (read-only inventory).",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "block_ip_address",
            "description": (
                "WRITE ACTION — propose denying inbound traffic from a hostile IP at the lab NSG. "
                "Simulated unless ENABLE_WRITE_TOOLS=true AND the operator approves interactively. "
                "Use only for IPs observed attacking fictional lab infrastructure."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "ip": {"type": "string", "description": "IPv4 address to deny"},
                    "reason": {"type": "string"},
                },
                "required": ["ip", "reason"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "isolate_node",
            "description": (
                "WRITE ACTION — quarantine a squadron resource by tagging it criticalOrbit=isolated. "
                "Simulated unless ENABLE_WRITE_TOOLS=true AND the operator approves interactively. "
                "Resource must exist inside this squadron's own resource group."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "resource_name": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["resource_name", "reason"],
            },
        },
    },
]


def dispatch(name: str, arguments: dict) -> dict:
    """Route a model tool-call to a handler + append to the audit log."""
    fn = FUNCTIONS.get(name)
    if fn is None:
        result = {"error": f"unknown tool '{name}'"}
    else:
        try:
            result = fn(**arguments)
        except Exception as exc:  # noqa: BLE001 — feed error back to the model
            result = {"error": f"{type(exc).__name__}: {exc}"}
    mode = "enabled" if _writes_enabled() else "simulated"
    _audit(name, arguments, mode, result)
    return result
