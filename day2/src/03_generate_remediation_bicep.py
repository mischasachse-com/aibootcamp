#!/usr/bin/env python3
"""
Project Critical Orbit — Day 2, Lab 2, Step 03: generate remediation Bicep.

Asks the chat model to draft a Bicep snippet that remediates the flagged NSG
rule (the fictional 'AllowAllInbound' rule). The output is UNTRUSTED MODEL
OUTPUT:

  * written to day2/generated/ (gitignored) — never into infra/
  * optionally syntax-checked with `az bicep build` when available
  * NEVER deployed — a human reviews the diff before anything is applied

Usage:
    python src/03_generate_remediation_bicep.py
    python src/03_generate_remediation_bicep.py --check   # run az bicep build too
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(REPO_ROOT / ".env")

DEFAULT_NSG = REPO_ROOT / "data" / "blackbox" / "nsg_export_ground_station.json"
DEFAULT_ANALYSIS = REPO_ROOT / "day2" / "generated" / "blackbox_analysis.json"
DEFAULT_OUT = REPO_ROOT / "day2" / "generated" / "nsg_remediation.bicep"


def load_flagged_rules() -> list[dict]:
    """Reuse the NSG auditor from step 01 (same directory, digit-prefixed)."""
    import importlib.util

    sibling = Path(__file__).resolve().parent / "01_parse_blackbox.py"
    spec = importlib.util.spec_from_file_location("parse_blackbox", sibling)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    nsg = json.loads(DEFAULT_NSG.read_text(encoding="utf-8"))
    return mod.flag_nsg_rules(nsg)


def maybe_bicep_build(path: Path) -> None:
    """Best-effort syntax check — never a deploy step."""
    az = shutil.which("az")
    if not az:
        print("[!] 'az' CLI not found — skipping optional `az bicep build` check.")
        return
    try:
        proc = subprocess.run(
            [az, "bicep", "build", "--file", str(path)],
            capture_output=True, text=True, timeout=120,
        )
        if proc.returncode == 0:
            print("[ok] `az bicep build` — generated snippet is syntactically valid")
        else:
            print("[!] `az bicep build` reported issues (model output is untrusted — review!):")
            print(proc.stderr or proc.stdout)
    except Exception as exc:  # noqa: BLE001
        print(f"[!] bicep build check skipped: {exc}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--output", default=str(DEFAULT_OUT))
    ap.add_argument("--check", action="store_true", help="run `az bicep build` syntax check on the output")
    args = ap.parse_args()

    flagged = load_flagged_rules()
    if not flagged:
        print("[ok] no overly-permissive NSG rules found — nothing to remediate.")
        return

    if DEFAULT_ANALYSIS.exists():
        context = json.loads(DEFAULT_ANALYSIS.read_text(encoding="utf-8"))
    else:
        context = {"nsg_findings": flagged}

    from azure.identity import DefaultAzureCredential
    from azure.ai.projects import AIProjectClient

    credential = DefaultAzureCredential()
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=credential
    )
    client = project.get_openai_client()

    system = (
        "You are a cloud security engineer writing Azure Bicep. You produce "
        "MINIMAL, reviewable remediation snippets — never whole deployments. "
        "Rules: (1) replace the flagged overly-permissive inbound Allow with "
        "explicit least-privilege rules matching the fictional ORBITNET "
        "addressing (10.42.x.0/24 enclaves; partner relay 203.0.113.64/28); "
        "(2) keep an explicit DenyAllInbound catch-all below priority 4096; "
        "(3) add a comment on every rule explaining the decision; (4) output "
        "ONLY valid Bicep — no markdown fences, no commentary."
    )
    user = (
        "Flagged NSG findings and their context follow. Produce a Bicep snippet "
        "(`Microsoft.Network/networkSecurityGroups/securityRules` resources) that "
        "remediates ONLY the flagged rules, preserving the legitimate ones:\n\n"
        + json.dumps(context.get("nsg_findings", flagged), indent=2)
        + "\n\nExisting rules for reference:\n"
        + DEFAULT_NSG.read_text(encoding="utf-8")
    )

    resp = client.chat.completions.create(
        model=os.environ["CHAT_MODEL_DEPLOYMENT"],
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
        temperature=0.0,
        max_completion_tokens=2000,
    )

    snippet = resp.choices[0].message.content.strip()
    # strip accidental markdown fences — model output is untrusted
    if snippet.startswith("```"):
        snippet = "\n".join(
            line for line in snippet.splitlines() if not line.startswith("```")
        ).strip()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "// ============================================================================\n"
        "// GENERATED BY AI — UNTRUSTED OUTPUT. REVIEW BEFORE USE. NEVER AUTO-DEPLOY.\n"
        f"// Generated for squadron .env RG: {os.getenv('AZURE_RESOURCE_GROUP', 'unknown')}\n"
        "// Remediates flagged rules: "
        + ", ".join(r["name"] for r in flagged)
        + "\n// ============================================================================\n\n"
    )
    out.write_text(header + snippet + "\n", encoding="utf-8")

    print(f"[ok] remediation snippet written to {out}")
    print("=" * 74)
    print("UNTRUSTED MODEL OUTPUT — review every line. This file is gitignored")
    print("and is never deployed automatically. Validated ≠ approved.")
    print("=" * 74)

    if args.check:
        maybe_bicep_build(out)


if __name__ == "__main__":
    main()
