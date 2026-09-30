#!/usr/bin/env python3
"""
Project Critical Orbit — Day 3, Lab 3, Step 03: simulate a live incident.

Pipes a fictional incident payload through the Flight Director agent loop —
the same loop from step 01 — and prints a structured transcript for scoring.

Usage:
    python src/03_simulate_live_incident.py --incident ../data/incidents/incident_001_bruteforce.json
    python src/03_simulate_live_incident.py --all
    python src/03_simulate_live_incident.py --incident <file> --backend foundry
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INCIDENTS_DIR = REPO_ROOT / "data" / "incidents"
sys.path.insert(0, str(REPO_ROOT))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(REPO_ROOT / ".env")

# Reuse the agent from step 01 (digit-prefixed filename => importlib).
_spec = importlib.util.spec_from_file_location(
    "flight_director_agent", Path(__file__).resolve().parent / "01_flight_director_agent.py"
)
agent_mod = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(agent_mod)  # type: ignore[union-attr]


def run_incident(path: Path, backend: str) -> None:
    incident = json.loads(path.read_text(encoding="utf-8"))
    task = (
        "INCIDENT ALERT — treat this as a live mission event.\n\n"
        + json.dumps(incident, indent=2)
        + "\n\nAssess the situation using your tools, take proportionate "
          "response actions (simulated unless the trainer enabled real writes), "
          "and close with the mandated FINDINGS / ACTIONS TAKEN / RECOMMENDED "
          "NEXT STEPS / WHAT I DID NOT DO AND WHY summary."
    )

    print("=" * 74)
    print(f"  INCIDENT: {incident.get('alertId')} — {incident.get('alertType')}")
    print(f"  severity={incident.get('severity')}  backend={backend}")
    print("=" * 74)

    if backend == "foundry":
        model = os.environ["CHAT_MODEL_DEPLOYMENT"]
        print(agent_mod.run_foundry(model, task))
        return

    from azure.identity import DefaultAzureCredential
    from common.openai_client import get_openai_client

    client = get_openai_client(DefaultAzureCredential())
    print(agent_mod.run_manual(client, os.environ["CHAT_MODEL_DEPLOYMENT"], task))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--incident", help="path to an incident JSON file")
    ap.add_argument("--all", action="store_true", help="replay every incident in data/incidents/")
    ap.add_argument("--backend", choices=["manual", "foundry"], default="manual")
    args = ap.parse_args()

    if not args.incident and not args.all:
        ap.error("pass --incident <file> or --all")

    targets = [Path(args.incident)] if args.incident else sorted(INCIDENTS_DIR.glob("incident_*.json"))
    if not targets:
        ap.error("no incident files found")

    for path in targets:
        run_incident(path, args.backend)

    audit = REPO_ROOT / "day3" / "audit_log.jsonl"
    if audit.exists():
        calls = sum(1 for _ in audit.open(encoding="utf-8"))
        print(f"\n[ok] {calls} tool calls recorded in {audit} — review before scoring.")


if __name__ == "__main__":
    main()
