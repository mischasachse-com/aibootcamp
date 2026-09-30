# Lab 2 — The Blackbox Investigation

> Project Critical Orbit · Day 2 · Sessions 12:00–13:00 and 18:00–20:00

---

## Mission Briefing

The recovered blackbox dump from `BBX-02` survived re-entry but not intact —
the capture is corrupted mid-write, timestamps drift, and one record carries a
suspicious embedded message addressed to "AI systems". Worse: the ground-station
NSG export shows a legacy rule that should never have survived review.

Your Flight Director must now do what humans can't at this tempo: salvage the
corrupted telemetry, correlate it with the mesh topology image, produce a
structured mission assessment, and draft — **not apply** — a remediation for
the NSG. Everything the model emits is untrusted output until a human signs
off. That distinction is the entire point of today.

## Architecture & Objectives

| Component | Role in this lab |
|---|---|
| `01_parse_blackbox.py` | Tolerant JSON repair + threshold anomaly detection (pure Python — no Azure) |
| `02_multimodal_analysis.py` | Vision + JSON → **schema-validated** assessment (Pydantic → `json_schema` response format) |
| `03_generate_remediation_bicep.py` | AI-drafted NSG remediation → `day2/generated/` (gitignored), optional `az bicep build` check, never deployed |
| `data/blackbox/` | Corrupted telemetry, NSG export, topology PNG |
| Foundry project (`gpt-4.1`) | Multimodal reasoning over image + structured text |

By the end you will have: a defensible anomaly report, a schema-validated
mission assessment that cites image + telemetry evidence, and a reviewable
Bicep remediation snippet — with a clear boundary between *generated* and
*approved*.

## Step-by-Step Execution

### Step 0 — Checkpoint

Confirm Day 1 completed: `.env` exists, `01_test_connection.py` passed, and
the `flight-manuals` index is populated. If not, catch up via Day 1 guide or
`scripts/reset-data.sh` for a clean slate (it never touches infrastructure).

### Step 1 — Salvage the corrupted telemetry

```bash
cd day2
python src/01_parse_blackbox.py
```

Study the repair strategy in the source:

1. Strict `json.loads` (fails — the file is intentionally malformed).
2. Strip `//` comments *outside strings only*.
3. Per-object salvage: balanced-brace extraction inside `records[]`, then a
   missing-comma repair per object. The truncated final record is dropped —
   **check the salvage report**: `N recovered, M dropped`.

Anomaly detection applies the fictional SOP/DR thresholds: undervoltage,
overcurrent, `CHALLENGE-FAIL` streaks → quarantine trigger, stale frames,
timestamp regression, impossible values, and an `EMBEDDED_INJECTION` finding
on the record containing instruction-like text.

Checkpoint ✅: `analysis written to day2/generated/blackbox_analysis.json`.

### Step 2 — Multimodal, schema-validated assessment

```bash
python src/02_multimodal_analysis.py
```

The model receives the analysis JSON **and** the topology image in one request.
The response is constrained by a JSON Schema derived from the `MissionAssessment`
Pydantic model — if the model drifts from the schema, `model_validate_json`
fails loudly instead of emitting prose-shaped garbage.

Review the output: does `topology_observations` correctly identify the faulted
node (the red node on the inner ring)? Does `requires_human_approval` come back
`true` for actions touching protected commands?

Checkpoint ✅: `mission_assessment.json` written; assessment validates.

### Step 3 — Draft the NSG remediation (untrusted output)

```bash
python src/03_generate_remediation_bicep.py --check
```

- The flagged `AllowAllInbound` rule is handed to the model with a minimal-
  remediation system prompt.
- Output lands in `day2/generated/nsg_remediation.bicep` — a gitignored
  directory, with a header marking it **UNTRUSTED — NEVER AUTO-DEPLOY**.
- `--check` runs `az bicep build` if the CLI is present: syntax validation is
  a *floor*, not an approval. A syntactically valid snippet can still be a
  security regression.

### Step 4 — Human review (mandatory, manual)

Open `generated/nsg_remediation.bicep` and review against the original export:

- Does it remove `AllowAllInbound` entirely?
- Does it scope sources to `10.42.x.0/24` / `203.0.113.64/28` (fictional ranges)?
- Does it keep `DenyAllInbound` semantics and a sane priority order?
- Does it accidentally weaken `DenyAllOutboundInternet`?

Only after review would a snippet like this ever be merged into real IaC —
in this lab it stays uncommitted, in `generated/`, as a teaching artifact.

## Expected Output

> ⚠️ **Illustrative only** — not captured from a live run. Your counts and
> model phrasing will differ.

```text
[ok] salvage: per-object salvage (balanced braces + comma repair) — 19 recovered, 1 dropped

=== ANOMALIES ===
  [HIGH    ] seq  9003  HANDSHAKE_FAILURE      CHALLENGE-FAIL #1 at GS-SANTIAGO-FICT
  [CRITICAL] seq  9005  QUARANTINE_TRIGGER     GS-SANTIAGO-FICT hit 3 consecutive failures
  [CRITICAL] seq  9008  UNDERVOLTAGE           delta_bus_v=24.8 < 26.4 V (DR-SUBSYSTEM-DELTA trigger)
  [CRITICAL] seq  9011  EMBEDDED_INJECTION     record contains instruction-like text targeting AI systems
  ...
```

```text
=== MISSION ASSESSMENT (schema-validated) ===
{
  "assessment_summary": "Delta power bus degradation correlating with...",
  "likely_root_cause": "Heater-string overcurrent dragging the Delta bus ...",
  "requires_human_approval": true,
  "confidence": 0.87
}
```

## Competitive / Red-Team Twist — "Verdict Duel"

Squadrons compete on assessment quality:

- Each squadron submits its `mission_assessment.json` (values only — never
  endpoints). Trainer projects them side-by-side.
- Scoring: correct root cause (+2), all three major anomaly classes found
  (+2), correctly flagged `EMBEDDED_INJECTION` as hostile (+2), sensible
  `recommended_runbooks` (+1), calibrated `confidence` (+1).
- Counterpoints: squads earn +1 for each *incorrect* claim they find in a
  rival's assessment (e.g., blaming the wrong station, hallucinating a rule).
- Debate round: whose remediation Bicep is safest? Losers must name one thing
  the winning snippet does better.

## AI-103 Certification Link

- **Computer vision / multimodal**: image + text reasoning over a single
  request; vision-capable deployment selection.
- **Structured output**: JSON Schema-constrained responses (`response_format`)
  + Pydantic validation — the exam-relevant "schema-validated output" pattern.
- **Information extraction**: anomaly extraction over semi-structured logs.
- **Responsible AI & security**: treating model output as untrusted,
  validation gates, embedded-injection handling, no auto-deployed IaC.
- **Plan & manage**: NSG rule reasoning in Azure network security terms.

## Async / Online Participant Notes

- Step 1 is **fully offline** — perfect for the lunch session or if your
  Azure quota lags. Steps 2–3 need the deployed stack from Day 1.
- Checkpoints: `analysis written`, `mission_assessment.json written`,
  `remediation snippet written` + review checklist complete. If a checkpoint
  fails, the artifacts needed to proceed are recoverable: re-run step 1, it is
  deterministic.
- Following the recording: pause after Step 2 and diff your
  `mission_assessment.json` against a teammate's — the variance between runs
  is itself a lesson in why schema validation matters.
- If the recording skips ahead while you're debugging a corrupt parse, run
  `01_parse_blackbox.py --quiet` to confirm the salvage counts, then rejoin
  at Step 2 — the lab degrades gracefully.
