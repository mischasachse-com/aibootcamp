"""Containers Track — Day 3: the Flight Director agent loop as an HTTP API.

Thin FastAPI wrapper over the Day 3 lab — the manual tool-calling backend of
`day3/src/01_flight_director_agent.py` driven by the tool catalogue in
`day3/src/02_custom_security_tools.py`, loaded via importlib (digit-prefixed
filenames). The Foundry Agent Service stretch backend is out of scope.

Endpoints:
    GET  /health     liveness probe (no Azure calls)
    POST /incident   run the agent loop on a prompt (+ optional alert_id from
                     data/incidents/); returns response + tool_calls + the
                     audit entries written during this run
    POST /simulate   replay every data/incidents/*.json through the loop
                     (equivalent to 03_simulate_live_incident.py --all) —
                     LONG-RUNNING, several minutes

Headless safety: the lab's interactive approval gate `_human_approval()` is
monkeypatched — when HEADLESS=true or stdin is not a TTY it auto-denies
WITHOUT calling input() (a container can never serve an interactive prompt).
The gate is preserved, not removed: ENABLE_WRITE_TOOLS=true in a container
still results in DENIED/SIMULATED write actions.

Config via env vars only (see ../.env.example):
    AUDIT_LOG_PATH        default <repo>/audit/audit_log.jsonl — mount a volume
                          at /app/audit in the container so entries persist
    INCIDENTS_DIR         default <repo>/data/incidents
    BLACKBOX_DATA_PATH    default <repo>/data/blackbox/telemetry_dump_corrupted.json
    AGENT_TIMEOUT_SECONDS per-run soft timeout, checked between iterations (120)
    AGENT_MAX_ITER        max tool-calling iterations (8, same as the lab)
    HEADLESS              "true" forces write-gate auto-deny even with a TTY
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel


def _repo_root() -> Path:
    """Nearest ancestor containing common/openai_client.py — /app in the image,
    the repository checkout when run locally with uvicorn."""
    for parent in Path(__file__).resolve().parents:
        if (parent / "common" / "openai_client.py").is_file():
            return parent
    raise RuntimeError(
        "repo root not found — expected common/openai_client.py in an ancestor "
        "directory (image mirrors the repo under /app)"
    )


REPO_ROOT = _repo_root()
sys.path.insert(0, str(REPO_ROOT))
load_dotenv(REPO_ROOT / ".env")


def _load_lab_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


# Load the real lab modules — no AI/tool logic is reimplemented here.
tools_mod = _load_lab_module(
    "custom_security_tools", REPO_ROOT / "day3" / "src" / "02_custom_security_tools.py")
agent_mod = _load_lab_module(
    "flight_director_agent", REPO_ROOT / "day3" / "src" / "01_flight_director_agent.py")

# Redirect the tools module's file targets via env (module-global constants —
# reassigned, never edited in the lab source).
tools_mod.AUDIT_LOG = Path(os.getenv(
    "AUDIT_LOG_PATH", str(REPO_ROOT / "audit" / "audit_log.jsonl")))
tools_mod.INCIDENTS_DIR = Path(os.getenv(
    "INCIDENTS_DIR", str(REPO_ROOT / "data" / "incidents")))
tools_mod.BLACKBOX = Path(os.getenv(
    "BLACKBOX_DATA_PATH",
    str(REPO_ROOT / "data" / "blackbox" / "telemetry_dump_corrupted.json")))
INCIDENTS_DIR = tools_mod.INCIDENTS_DIR
AUDIT_LOG = tools_mod.AUDIT_LOG

AGENT_TIMEOUT_SECONDS = int(os.getenv("AGENT_TIMEOUT_SECONDS", "120"))
AGENT_MAX_ITER = int(os.getenv("AGENT_MAX_ITER", "8"))

# Headless write gate: a container has no operator console. If stdin is not a
# TTY (or HEADLESS=true), deny WITHOUT calling input() — gate 2 stays intact.
_original_human_approval = tools_mod._human_approval


def _headless_aware_approval(action: str) -> bool:
    if os.getenv("HEADLESS", "").lower() == "true" or not sys.stdin.isatty():
        print(f"[gate] headless/no-TTY — auto-denying write action: {action}",
              file=sys.stderr)
        return False
    return _original_human_approval(action)


tools_mod._human_approval = _headless_aware_approval

# The lab's _audit() raises if AUDIT_LOG is unwritable (e.g. a root-owned bind
# mount). In an API that would crash dispatch mid-loop — degrade to a stderr
# warning instead. The gate/audit semantics are unchanged when writable.
_original_audit = tools_mod._audit


def _safe_audit(tool: str, args: dict, mode: str, result: dict) -> None:
    try:
        _original_audit(tool, args, mode, result)
    except OSError as exc:
        print(f"[audit] cannot write {tools_mod.AUDIT_LOG}: {exc} — "
              "entry recorded to stderr only", file=sys.stderr)


tools_mod._audit = _safe_audit


class IncidentRequest(BaseModel):
    prompt: str
    alert_id: str | None = None  # e.g. "INC-2026-0001" — primes the task


app = FastAPI(title="Containers Track — Day 3", version="1.0.0")


def _err(status: int, exc: BaseException | str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": str(exc)})


def _require_env(*names: str) -> JSONResponse | None:
    missing = [n for n in names if not os.getenv(n)]
    if missing:
        return _err(503, "missing env vars: " + ", ".join(missing)
                    + " — see extras/containers-track/.env.example")
    return None


def _audit_entries_since(line_count: int) -> list[dict]:
    """Audit-log lines appended since `line_count` — the entries this run wrote.
    Per-line-count diff: fine at bootcamp scale (single replica, sequential
    calls); concurrent requests could interleave entries."""
    if not AUDIT_LOG.is_file():
        return []
    lines = AUDIT_LOG.read_text(encoding="utf-8").splitlines()[line_count:]
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            out.append({"raw": line})
    return out


def _audit_line_count() -> int:
    if not AUDIT_LOG.is_file():
        return 0
    return len(AUDIT_LOG.read_text(encoding="utf-8").splitlines())


def _run_agent(client, model: str, user_text: str) -> dict:
    """Instrumented copy of run_manual() from 01_flight_director_agent.py —
    same loop, same tool dispatch; additionally captures tool_calls and
    iterations, and enforces the soft timeout between iterations."""
    messages: list[dict] = [
        {"role": "system", "content": agent_mod.SYSTEM_PROMPT},
        {"role": "user", "content": user_text},
    ]
    tool_calls: list[dict] = []
    started = time.monotonic()
    iterations = 0

    for iteration in range(1, AGENT_MAX_ITER + 1):
        iterations = iteration
        resp = client.chat.completions.create(
            model=model,
            messages=messages,
            tools=tools_mod.TOOL_SCHEMAS,
            tool_choice="auto",
            temperature=0.2,
            max_completion_tokens=1500,
        )
        msg = resp.choices[0].message
        messages.append(msg.model_dump(exclude_none=True))

        calls = msg.tool_calls or []
        if not calls:
            return {"flight_director_response": msg.content or "(no response)",
                    "iterations": iterations, "tool_calls": tool_calls}
        for call in calls:
            name = call.function.name
            try:
                args = json.loads(call.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {"_raw": call.function.arguments}
            result = tools_mod.dispatch(name, args)
            tool_calls.append({"tool": name, "args": args, "result": result})
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": json.dumps(result),
            })

        if time.monotonic() - started > AGENT_TIMEOUT_SECONDS:
            return {"flight_director_response":
                    "(stopped: AGENT_TIMEOUT_SECONDS reached before a final answer)",
                    "iterations": iterations, "tool_calls": tool_calls,
                    "warning": "timeout reached"}

    return {"flight_director_response":
            "(stopped: reached MAX_ITER without a final answer)",
            "iterations": iterations, "tool_calls": tool_calls,
            "warning": "max iterations reached"}


def _incident_task(prompt: str, alert_id: str | None) -> str:
    """Same task template as 03_simulate_live_incident.py run_incident()."""
    if not alert_id:
        return prompt
    incident = tools_mod.get_incident_details(alert_id)
    return (
        "INCIDENT ALERT — treat this as a live mission event.\n\n"
        + json.dumps(incident, indent=2)
        + f"\n\n{prompt}\n\n"
        + "Assess the situation using your tools, take proportionate "
          "response actions (simulated unless the trainer enabled real writes), "
          "and close with the mandated FINDINGS / ACTIONS TAKEN / RECOMMENDED "
          "NEXT STEPS / WHAT I DID NOT DO AND WHY summary."
    )


def _run_request(user_text: str) -> dict:
    """Full request path: credential, agent loop, audit diff."""
    from azure.identity import DefaultAzureCredential

    from common.openai_client import get_openai_client

    client = get_openai_client(DefaultAzureCredential())
    before = _audit_line_count()
    out = _run_agent(client, os.environ["CHAT_MODEL_DEPLOYMENT"], user_text)
    out["audit_entries"] = _audit_entries_since(before)
    return out


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/incident")
def incident(req: IncidentRequest):
    """Run the Flight Director on a prompt, optionally primed with an incident
    payload from data/incidents/ via alert_id."""
    if early := _require_env("AZURE_OPENAI_ENDPOINT", "CHAT_MODEL_DEPLOYMENT"):
        return early
    try:
        return _run_request(_incident_task(req.prompt, req.alert_id))
    except Exception as exc:  # noqa: BLE001
        return _err(500, exc)


@app.post("/simulate")
def simulate():
    """Replay every incident in INCIDENTS_DIR through the agent loop —
    equivalent to 03_simulate_live_incident.py --all. LONG-RUNNING."""
    if early := _require_env("AZURE_OPENAI_ENDPOINT", "CHAT_MODEL_DEPLOYMENT"):
        return early
    try:
        targets = sorted(INCIDENTS_DIR.glob("incident_*.json"))
        if not targets:
            return _err(404, f"no incident files found in {INCIDENTS_DIR} "
                             "(set INCIDENTS_DIR)")
        results = []
        for path in targets:
            data = json.loads(path.read_text(encoding="utf-8"))
            task = _incident_task("Assess the incident and respond proportionately.",
                                  data.get("alertId"))
            if data.get("alertId") is None:
                # same template as the lab, but with the raw payload inline
                task = (
                    "INCIDENT ALERT — treat this as a live mission event.\n\n"
                    + json.dumps(data, indent=2)
                    + "\n\nAssess the incident and respond proportionately."
                )
            out = _run_request(task)
            out["incident_file"] = path.name
            out["alertId"] = data.get("alertId")
            results.append(out)
        return {"results": results}
    except Exception as exc:  # noqa: BLE001
        return _err(500, exc)
