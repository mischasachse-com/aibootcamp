# AGENTS.md — Project Critical Orbit

Guidance for AI coding agents (GitHub Copilot, Devin, Codex, etc.) working in
this repository. Read `README.md` first — it is the authoritative source for
the scenario, prerequisites, and trainer procedures.

## What this repo is

A 3-day enterprise AI engineering bootcamp (fictional scenario: ORBITAL-NET
ground control). Participants deploy real Azure resources into per-squadron
resource groups and build an AI "Flight Director" on Microsoft Foundry.

- `day1/` — Bicep infra (`infra/main.bicep`), indexing + grounded Q&A lab
- `day2/` — corrupted blackbox forensics, multimodal analysis, remediation lab
- `day3/` — agent loop with gated security tools, incident simulator
- `common/` — shared Python helpers (`openai_client.py` client factory)
- `scripts/` — **participant-safe** scripts (`setup-squadron.sh`, `reset-data.sh`)
- `scripts/lib/` — shared shell helpers (`common.sh`, sourced — do not execute directly)
- `trainer/` — **trainer-only** tooling (preflight, teardown, RBAC, roster)
- `presentation/` — trainer-facing slide decks (Kickoff + Day1–3, self-contained
  HTML, English, mischasachse.com brand — no timing/duration content)
- `tests/` — offline pytest suite; no Azure access required
- `data/` — fictional scenario assets; `telemetry_dump_corrupted.json` is
  intentionally malformed — do NOT "fix" it
- `azure-pipelines.yml` — Azure Pipelines CI on Azure Repos (not GitHub)

## Verify changes (all offline, no Azure needed)

```bash
pip install -r requirements.txt
pytest tests/ -v                          # unit tests + shell-logic regression tests
ruff check day1 day2 day3 common tests    # lint
python -m compileall -q day1 day2 day3 common tests
az bicep build --file day1/infra/main.bicep
shellcheck -S warning scripts/*.sh scripts/lib/*.sh trainer/*.sh
bash -n <script>.sh                       # per-file shell syntax check
```

CI runs exactly this set. Match it before claiming a change is done.

## Hard rules

- **No secrets, ever.** Auth is Entra-only (`DefaultAzureCredential`,
  `get_bearer_token_provider`, `az login`). Never add API keys, connection
  strings with credentials, or key-based auth to code, `.env`, or examples.
  `.env` itself is gitignored and must never be committed.
- **Never deploy from automation.** CI deliberately has no deploy steps.
  `setup-squadron.sh`, `teardown-all.sh`, and `az deployment` commands are
  interactive human decisions — do not run them without being asked.
- **`trainer/` is trainer-only.** Do not wire trainer scripts into
  participant flows or docs.
- **Respect squadron isolation.** Everything targets the participant's own
  `rg-corbit-sq<NN>` resource group; no cross-subscription/resource-group
  assumptions.
- **Day 3 write tools stay gated.** `ENABLE_WRITE_TOOLS=false` by default;
  writes always require interactive human approval. Never bypass this.
- **Participants cannot self-assign RBAC.** `Contributor` lacks
  `roleAssignments/write`; data-plane roles are pre-assigned by the trainer.
  Don't generate code/docs implying otherwise.

## Conventions

- **Fictional data**: IPs follow RFC 5737/1918; incidents, orgs, and the
  "secret" authorization code are training props — not real security issues.
- **Python ≥ 3.10** (devcontainer: 3.12). Exact pins in `requirements.txt` —
  treat it like a lock file; bump deliberately and re-run the full suite.
- **LF endings everywhere** (`.gitattributes` enforces it, including on
  Windows). Indent: 4 spaces Python, 2 spaces Bicep/shell/JSON/YAML.
- **Lint style**: ruff for Python, shellcheck (`-S warning`) for shell.
  Follow existing header-comment style in scripts.
- **OpenAI client**: always use `common/openai_client.py:get_openai_client()`
  — chat/embeddings go to `AZURE_OPENAI_ENDPOINT`
  (`<account>.openai.azure.com/openai/v1/`). The Foundry *project* endpoint
  (`FOUNDRY_PROJECT_ENDPOINT`) 404s on embeddings and is only for the Day 3
  Foundry Agent Service stretch (azure-ai-agents SDK).
- **Bicep must stay idempotent** — `setup-squadron.sh` is re-runnable and
  repairs partial deploys. `assignDataPlaneRoles` stays `false` by default.
- **Docs**: update `README.md` (and lab guides if relevant) when behavior,
  commands, or troubleshooting steps change. Keep the Troubleshooting table
  accurate — it is participant-facing.
