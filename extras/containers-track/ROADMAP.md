# Containers Track — Roadmap (days beyond Day 1)

> **Draft — labs may still change. Review before building.**
> Written against the lab sources as of this PR. Day 2 and Day 3 have since
> been built per this assessment; keep this document as the design record.

## Assessment method

For each day: which lab is the best container candidate (a request/response
or job-shaped workload — not an interactive REPL), what the container variant
adds, participant effort, and risks.

## Day 2 — The Blackbox Investigation

- **Candidate**: the whole three-step pipeline
  (`01_parse_blackbox.py` → `02_multimodal_analysis.py` →
  `03_generate_remediation_bicep.py`), exposed as `POST /parse`,
  `POST /assess`, `POST /remediation`.
- **What the container adds**: the forensic pipeline becomes a reusable HTTP
  service. `POST /parse` needs no credentials at all (pure Python), which
  makes it a nice incremental smoke test. `POST /assess` shows multimodal
  input (image + JSON) over HTTP; `POST /remediation` demonstrates that
  *generated* artifacts can be served as untrusted payloads with an explicit
  warning field — the same generated-vs-approved boundary as the script lab.
- **Data access**: `data/blackbox/` (telemetry, NSG export, topology PNG) is
  COPYed into the image; a read-only mount is the alternative.
- **Effort**: low–medium. The scripts already isolate pure functions
  (`load_telemetry`, `detect_anomalies`, `flag_nsg_rules`, `build_analysis`,
  `MissionAssessment`) so the wrapper is thin.
- **Risks**: schema-drift 422s are the model's normal failure mode —
  surface them as API errors, don't hide them. The remediation endpoint must
  never write into `day1/infra/` or trigger a deploy path.

## Day 3 — The Flight Director (agent loop)

- **Candidate**: `01_flight_director_agent.py` **manual backend only**,
  exposed as `POST /incident` (single alert or free-form prompt) and
  `POST /simulate` (replay `data/incidents/` — equivalent to
  `03_simulate_live_incident.py --all`). The Foundry Agent Service stretch
  backend stays script-only.
- **What the container adds**: incident response becomes an API the rest of
  a toolchain could call; the response includes the full tool-call trace and
  the audit entries written during the run — observability by construction.
- **Hard constraint — write tools**: the interactive approval gate cannot
  work in a container (no TTY). The lab file is not modified; the app
  monkeypatches `_human_approval` to auto-deny when `HEADLESS=true` or stdin
  is not a TTY. `ENABLE_WRITE_TOOLS` therefore has no effect in the
  container — **by design**. Real write execution is a non-goal.
- **Audit log**: `AUDIT_LOG_PATH` (default `/app/audit/audit_log.jsonl`) with
  a volume mount so entries survive restarts. In Container Apps a persistent
  share needs a mounted volume — production consideration, not implemented
  here (see day3/README.md for the docs link).
- **Effort**: medium–high. The loop must be instrumented (tool_calls,
  iterations, soft timeout) and file paths/env vars redirected without
  touching lab sources.
- **Risks**: `list_squadron_resources` and real write tools shell out to the
  `az` CLI, which is not in the image — those tools degrade to a structured
  `{"error": ...}` fed back to the model (the agent keeps working). The
  soft timeout is checked between iterations, not mid-HTTP-call. `/simulate`
  is long-running (one agent run per incident × N minutes).

## Beyond the bootcamp (not built — ideas only)

| Idea | Why | Effort |
|---|---|---|
| Indexing as a job container (`02_index_flight_manuals`) | one-shot ingestion job in ACA Jobs | medium |
| Evaluation harness container | batch-run prompts, emit scores | medium |
| Foundry Agent Service backend behind the same API | managed threads/runs comparison | high |
