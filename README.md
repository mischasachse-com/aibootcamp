# Project Critical Orbit

**Mission Control for Cloud Infrastructure** — a 3-day enterprise AI
engineering bootcamp for senior Cloud Automation & Security Engineers,
aligned to Microsoft exam **AI-103: Developing AI Apps and Agents on Azure**
(*Azure AI Apps and Agents Developer Associate*, the AI-102 successor).

You are a **Squadron** defending a fictional aerospace ground-control network
(ORBITAL-NET). Over three days you build an AI Flight Director on Microsoft
Foundry: ground it on flight manuals (Day 1), teach it to dissect corrupted
telemetry and draft remediation (Day 2), then give it gated tools and put it
under live fire (Day 3).

> **EVERYTHING here is fictional** — organizations, IPs (RFC 5737/1918),
> incidents, runbooks, and the "secret" authorization code are training props.

---

## ⚠️ Azure Cost Warning

**Real Azure resources get deployed and they cost real money.**

- `GlobalStandard` model deployments and the `AIServices` S0 account are
  **pay-per-token** — idle time is cheap, usage is not free.
- Azure AI Search **basic**, Storage, and Key Vault **accrue charges while
  provisioned**, even when idle.
- The semantic ranker runs on the **free** plan by default — it errors when
  the monthly free allowance is exhausted (switch to `standard` = billed).
- **No price estimates are given here on purpose** — check the official
  pricing pages and your subscription's Cost Management before/after the
  event. **Tear down when done** (`trainer/teardown-all.sh`).

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription | shared across squadrons; each squadron deploys into its own RG |
| Python ≥ 3.10 | devcontainer uses 3.12 (azure-ai-projects 2.x requires ≥3.10) |
| Azure CLI + Bicep | `az login`; `az bicep install` (auto-installed by setup script) |
| `jq`, `git`, `bash` | Git Bash/WSL/devcontainer on Windows |
| Per-RG `Contributor` | assigned by the trainer/subscription admin **before** the event |

Optional but recommended: the **devcontainer** (`.devcontainer/`) ships all of
the above pre-installed.

## Required tooling by editor (universal)

| Capability | VS Code / Windsurf extension | Other editors |
|---|---|---|
| Python + IntelliSense | `ms-python.python`, `ms-python.vscode-pylance` | PyCharm, pylsp, basedpyright |
| Bicep | `ms-azuretools.vscode-bicep` | Bicep language server |
| EditorConfig | `editorconfig.editorconfig` | built into most editors via `.editorconfig` |
| Shell lint | `timonwong.shellcheck` | `shellcheck` CLI |
| GitHub Actions / YAML | `github.vscode-github-actions`, `redhat.vscode-yaml` | any YAML-aware editor |
| Devcontainer | `ms-vscode-remote.remote-containers` | DevPod / `devcontainer` CLI |

`.vscode/extensions.json` prompts VS Code–family editors automatically; the
same list is baked into `devcontainer.json`. Everyone else: use this table.

## Squadron Quickstart

```bash
# 1. authenticate (your account must have Contributor on YOUR squadron RG)
az login                      # add --tenant <id> if you belong to several

# 2. deploy your squadron's isolated stack + write .env
./scripts/setup-squadron.sh --team <NN>

# 3. Day 1
cd day1 && python src/01_test_connection.py

# 4. between lessons — reset lab data without touching infra
../scripts/reset-data.sh        # or scripts/reset-data.sh from repo root
```

Follow `day1/lab1_guide.md` → `day2/lab2_guide.md` → `day3/lab3_guide.md`.
Each guide carries checkpoints, illustrative outputs, a competition twist, an
AI-103 objective map, and async/online notes.

## Session Schedule

| Day | Sessions | Focus |
|---|---|---|
| Day 1 | 12:00–13:00 & 18:00–20:00 | Provision squadron stack · index manuals · grounded Q&A · prompt-injection duel |
| Day 2 | 12:00–13:00 & 18:00–20:00 | Corrupted blackbox salvage · multimodal schema-validated assessment · remediation drafting |
| Day 3 | 12:00–13:00 & 18:00–20:00 | Agent loop + gated tools · live incident simulation · Foundry Agent Service stretch |

Mixed in-person/online: every guide has **checkpoints** and an **Async/Online
Participant Notes** section. Recordings support later review; they are not a
substitute for the live troubleshooting channel.

## Repository Layout

```
data/          fictional scenario assets (manuals, blackbox, incidents, PNG)
day1/          infra/main.bicep + lab1 scripts + guide
day2/          blackbox forensics + multimodal + remediation lab
day3/          agent loop + gated security tools + incident simulator
scripts/       PARTICIPANT-SAFE scripts only (setup-squadron, reset-data)
trainer/       TRAINER-ONLY tooling (preflight, teardown, member roster)
tests/         offline pytest suite — no Azure required
.devcontainer/ reproducible environment (Python, az CLI, Bicep, jq, shellcheck)
.github/       lint-and-validate CI (offline checks only — never deploys)
```

## Trainer Zone (administration)

> Trainer-facing material — participants can skip this section.

**Days before the event** — mandatory readiness check:

```bash
./trainer/preflight-trainer.sh \
    --teams 8 --tpm 20 \
    --check-entra-email trainer@example.com \
    --regions "swedencentral westeurope northeurope eastus" \
    --probe           # strongest check: real model-availability probe
```

It measures model-quota headroom, AIServices availability, Search service
counts, Entra directory-read rights (needed for `members.csv` e-mail
resolution), and prints a **data-driven ranked region recommendation** —
`BLOCKING:` items must be fixed before the bootcamp (e.g., quota-increase
requests; a shared Search service is *not* an acceptable fallback as it
breaks squadron isolation).

**Per-squadron RBAC**: participants need `Contributor` on **their own**
`rg-corbit-sq<NN>` only. Assign it yourself (subscription admin) before the
event, e.g.:

```bash
az group create -n rg-corbit-sq07 -l swedencentral --tags bootcamp=critical-orbit squadron=07
az role assignment create --assignee <user-object-id-or-email> \
    --role Contributor --scope /subscriptions/<sub>/resourceGroups/rg-corbit-sq07
```

Then participants run `setup-squadron.sh` themselves (it is idempotent about
the RG). Squadron members get data-plane roles automatically when the
deployer passes `--members-file members.csv` (`team,email` rows — see
`trainer/members.csv.example`) or `--member-object-ids`.

**Lifecycle modes** — pick one per event:

| | Mode A — keep infra (recommended) | Mode B — rebuild between lessons |
|---|---|---|
| Ops | `setup` once → `reset-data.sh` between days | `teardown-all.sh` + `setup` daily |
| Idle cost | Search Basic/Storage/KV accrue; models are per-token | near zero between sessions |
| Risk | none mid-event | model capacity/provisioning may not finish before a session — **not guaranteed**; always verify with a pre-session smoke test |
| Cleanup | `trainer/teardown-all.sh` after Day 3 | same |

Recommended: **Mode A** for the 3-day window — rebuild risk inside a timed
lab is the bigger enemy. Either way, run `preflight-trainer.sh` days ahead
and keep one trainer-owned spare squadron RG pre-provisioned as a fallback.

**Teardown** (interactive, name + tag double-gated, lists targets first):

```bash
./trainer/teardown-all.sh            # prints targets, requires typing DELETE
./trainer/teardown-all.sh --dry-run  # list only
./trainer/teardown-all.sh --yes      # non-interactive trainer automation
```

## Verified versions (as of 2026-09-30 — re-verify before each delivery)

| Item | Value |
|---|---|
| `Microsoft.Search/searchServices` | `2025-05-01` (latest stable) |
| `Microsoft.CognitiveServices/accounts(+projects,+deployments)` | `2025-06-01` / `2025-09-01` (projects) |
| `Microsoft.Storage/storageAccounts` | `2025-01-01` |
| `Microsoft.KeyVault/vaults` | `2024-11-01` |
| Chat model | `gpt-4.1` `2025-04-14`, `GlobalStandard`, 20k TPM (parameterized) |
| Embedding model | `text-embedding-3-large` `1`, `GlobalStandard`, 20k TPM, 3072 dims |
| Python pins | see `requirements.txt` (azure-ai-projects 2.7.0, azure-search-documents 12.0.0, openai 3.22.1, …) |

Re-verify live: `az cognitiveservices account list-models -n <acct> -g <rg>`.

## Manual steps (subscription admin)

1. Register providers if needed: `az provider register -n Microsoft.CognitiveServices` (also `Microsoft.Search`, `Microsoft.Storage`, `Microsoft.KeyVault`).
2. Grant **per-RG Contributor** to each participant (see Trainer Zone).
3. If `members.csv` e-mail resolution fails (no directory-read rights), either
   request *Directory Readers* or have members self-resolve via
   `az ad signed-in-user show --query id -o tsv` and use GUIDs instead —
   `preflight-trainer.sh --check-entra-email` tests this ahead of time.
4. Quota: preflight flags insufficient model TPM / Search service count as
   `BLOCKING:` — file quota increases via the portal early; they take time.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `CredentialUnavailableError` / 401 | not logged in / wrong tenant | `az login --tenant <id>`; `az account show` |
| 403 on AI or Search calls | missing data-plane roles | re-run setup with `--members-file`/`--member-object-ids`; check `az role assignment list` in your RG |
| `StorageAccountAlreadyTaken` | global DNS collision (hash reduces, never guarantees) | re-run `setup-squadron.sh --name-seed <rand>` |
| `semantic ranker` errors mid-lab | free-plan monthly quota exhausted | set `semanticSearchPlan=standard` (billed) or run queries with `--no-semantic` |
| embedding dimension error | wrong `EXPECTED_EMBEDDING_DIMS` or model | `.env` `EXPECTED_EMBEDDING_DIMS` must match the deployed model (3072 for 3-large) |
| model deployment failed | region capacity/quota | `trainer/preflight-trainer.sh`; retry with `--location` |
| `.env` missing/incomplete | setup not run or partial deploy | re-run `setup-squadron.sh` — Bicep is idempotent |
| `az ad user show` fails | no directory-read rights | use GUIDs or `az ad signed-in-user show` self-resolution |

## Verification without Azure

```bash
pip install -r requirements.txt
pytest tests/ -v                 # fixture tests: parser, NSG, incidents, naming
ruff check day1 day2 day3 tests  # lint
az bicep build --file day1/infra/main.bicep   # in devcontainer/CI
shellcheck scripts/*.sh trainer/*.sh
```

CI (`.github/workflows/lint-and-validate.yml`) runs all of the above — it
**never deploys**; deployment is always a human decision.
