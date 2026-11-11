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
| --- | --- |
| Azure subscription | shared across squadrons; each squadron deploys into its own RG |
| Python ≥ 3.10 | devcontainer uses 3.12 (azure-ai-projects 2.x requires ≥3.10); on Windows Git Bash `python3` may be missing or a Store stub — the scripts auto-detect `python`/`py`, but `python` must work |
| Azure CLI + Bicep | `az login`; `az bicep install` (auto-installed by setup script) |
| `jq`, `git`, `bash` | Git Bash/WSL/devcontainer on Windows |
| Per-RG `Contributor` **+ six data-plane roles** | both assigned by the trainer/subscription admin **before** the event — see Trainer Zone. `Contributor` alone is NOT sufficient to self-assign RBAC. |

Optional but recommended: the **devcontainer** (`.devcontainer/`) ships all of
the above pre-installed. It is used **locally** via the VS Code Dev Containers
extension (`ms-vscode-remote.remote-containers`) — Docker Desktop required;
there is no cloud-hosted Codespaces-style flow.

## Required tooling by editor (universal)

| Capability | VS Code / Windsurf extension | Other editors |
| --- | --- | --- |
| Python + IntelliSense | `ms-python.python`, `ms-python.vscode-pylance` | PyCharm, pylsp, basedpyright |
| Bicep | `ms-azuretools.vscode-bicep` | Bicep language server |
| EditorConfig | `editorconfig.editorconfig` | built into most editors via `.editorconfig` |
| Shell lint | `timonwong.shellcheck` | `shellcheck` CLI |
| Azure Pipelines / YAML | `ms-azure-devops.azure-pipelines`, `redhat.vscode-yaml` | any YAML-aware editor |
| Devcontainer | `ms-vscode-remote.remote-containers` | DevPod / `devcontainer` CLI |

`.vscode/extensions.json` prompts VS Code–family editors automatically; the
same list is baked into `devcontainer.json`. Everyone else: use this table.

## Squadron Quickstart

```bash
# 1. authenticate (your account needs Contributor + the trainer-assigned
#    data-plane roles on YOUR squadron RG)
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
| --- | --- | --- |
| Day 1 | 12:00–13:00 & 18:00–20:00 | Provision squadron stack · index manuals · grounded Q&A · prompt-injection duel |
| Day 2 | 12:00–13:00 & 18:00–20:00 | Corrupted blackbox salvage · multimodal schema-validated assessment · remediation drafting |
| Day 3 | 12:00–13:00 & 18:00–20:00 | Agent loop + gated tools · live incident simulation · Foundry Agent Service stretch |

Mixed in-person/online: every guide has **checkpoints** and an **Async/Online
Participant Notes** section. Recordings support later review; they are not a
substitute for the live troubleshooting channel.

## Repository Layout

```
data/               fictional scenario assets (manuals, blackbox, incidents, PNG)
day1/               infra/main.bicep + lab1 scripts + guide
day2/               blackbox forensics + multimodal + remediation lab
day3/               agent loop + gated security tools + incident simulator
common/             shared Python helpers (OpenAI client factory)
scripts/            PARTICIPANT-SAFE scripts only (setup-squadron, reset-data)
scripts/lib/        shared shell helpers (common.sh — sourced, tested offline)
trainer/            TRAINER-ONLY tooling (preflight, teardown, RBAC assignment, roster)
tests/              offline pytest suite — no Azure required
.devcontainer/      reproducible environment (Python, az CLI, Bicep, jq, shellcheck)
azure-pipelines.yml Azure Pipelines CI (offline checks only — never deploys)
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

**Per-squadron RBAC** — participants get TWO layers on their own
`rg-corbit-sq<NN>`, both pre-assigned by you (subscription admin). Do not
tell participants Contributor is enough:

1. **Management plane**: `Contributor` on the RG — required for
   `az deployment group create` inside it.
2. **Data plane**: the six lab roles (`Cognitive Services OpenAI User`,
   `Cognitive Services User`, `Search Service Contributor`,
   `Search Index Data Contributor`, `Storage Blob Data Contributor`,
   `Key Vault Secrets Officer`).

Participants CANNOT self-assign: `Contributor` lacks
`Microsoft.Authorization/roleAssignments/write`, which is why the Bicep
template ships with `assignDataPlaneRoles=false`. Assign both layers
yourself before the event:

```bash
# management plane (once per RG per member)
az group create -n rg-corbit-sq07 -l swedencentral --tags bootcamp=critical-orbit squadron=07
az role assignment create --assignee <user-object-id-or-email> \
    --role Contributor --scope /subscriptions/<sub>/resourceGroups/rg-corbit-sq07

# data plane — all six roles at RG scope, driven by the roster CSV
./trainer/assign-squadron-access.sh --all-teams --members-file members.csv --dry-run
./trainer/assign-squadron-access.sh --all-teams --members-file members.csv --yes
```

`members.csv` rows are `team,identity[,type]` (identity = Entra e-mail or raw
object ID; `type` = User|Group|ServicePrincipal — groups/SPNs need object
IDs). See `trainer/members.csv.example`. Admins who DO have
`roleAssignments/write` can alternatively let `setup-squadron.sh
--assign-roles` create the assignments inside the deployment itself.

**Lifecycle modes** — pick one per event:

| | Mode A — keep infra (recommended) | Mode B — rebuild between lessons |
| --- | --- | --- |
| Ops | `setup` once → `reset-data.sh` between days | `teardown-all.sh` + `setup` daily |
| Idle cost | Search Basic/Storage/KV accrue; models are per-token | near zero between sessions |
| Risk | none mid-event | model capacity/provisioning may not finish before a session — **not guaranteed**; always verify with a pre-session smoke test |
| Soft-delete | n/a | **Key Vault + AIServices stay soft-deleted** after teardown, so a redeploy with the same squadron number fails on name conflicts — run `teardown-all.sh --purge` (or pass `--name-seed` on rebuild) |
| Cleanup | `trainer/teardown-all.sh` after Day 3 | same |

Recommended: **Mode A** for the 3-day window — rebuild risk inside a timed
lab is the bigger enemy. Either way, run `preflight-trainer.sh` days ahead
and keep one trainer-owned spare squadron RG pre-provisioned as a fallback.

**Semantic-ranker quota signal**: when a squadron hits the free-plan monthly
quota, `day1/src/03_query_flight_manual.py` falls back to non-semantic search
and appends a JSON line to `semantic_fallbacks.log` in the repo root. Ask
squadrons to check (`cat semantic_fallbacks.log`) or collect the files —
there is no central monitor.

**Teardown** (interactive, name + tag double-gated, lists targets first):

```bash
./trainer/teardown-all.sh            # prints targets, requires typing DELETE
./trainer/teardown-all.sh --purge    # also purge convention-matching soft-deleted
                                     # Key Vaults + AIServices accounts (asks again)
./trainer/teardown-all.sh --dry-run  # list only
./trainer/teardown-all.sh --yes      # non-interactive trainer automation
```

## Azure DevOps setup (one-time, trainer)

The CI for this repo is **Azure Pipelines** (`azure-pipelines.yml`), hosted in
Azure Repos — not GitHub. One-time manual prerequisites:

1. **Organization + project**: if none exists, create both at
   `dev.azure.com` (Organization settings are per-org). Create a project
   (e.g. `critical-orbit`).
2. **Import this repo** into Azure Repos: Repos → Files → Import, or push
   the local repo to the new remote. All `.sh` files must keep LF endings —
   the committed `.gitattributes` enforces this; don't strip it.
3. **Service connection (Workload Identity)**: Project settings → Service
   connections → New → **Azure Resource Manager** → **Workload identity
   federation (automatic)** → name it `sc-critical-orbit` (the name is a
   pipeline variable, changeable there), scope it to the bootcamp
   subscription, resource group optional. No secrets are stored. The
   pipeline's bicep job runs `az` through this connection; the federated
   credential needs no data-plane roles — only enough to run `az` in the
   subscription context (Reader suffices for the current pipeline).
4. **Create the pipeline**: Pipelines → New → Azure Repos Git → select the
   repo → the existing `azure-pipelines.yml` is picked up automatically.
5. **PR gating is NOT in the YAML on Azure Repos** (`pr:` triggers only work
   for GitHub-hosted code). Instead: Repos → Policies → Branch policies on
   `main` → enable **Build validation** → select this pipeline
   (path-triggered, automatic). Recommended alongside: minimum reviewers,
   comment resolution, "reset votes on new commits".
6. **Secret scanning**: available only if the org has GitHub Advanced
   Security for Azure DevOps enabled — it is NOT on by default and is
   license-dependent. If unavailable, the pipeline's own regex secret-scan
   step is the only check; treat it as a floor, not a guarantee.

## Verified versions (as of 2026-09-30 — re-verify before each delivery)

| Item | Value |
| --- | --- |
| `Microsoft.Search/searchServices` | `2025-05-01` (latest stable) |
| `Microsoft.CognitiveServices/accounts(+projects,+deployments)` | `2025-06-01` / `2025-09-01` (projects) |
| `Microsoft.Storage/storageAccounts` | `2025-01-01` |
| `Microsoft.KeyVault/vaults` | `2024-11-01` |
| Chat model | `gpt-4.1` `2025-04-14`, `GlobalStandard`, 20k TPM (parameterized) — **check the retirement date shortly before each bootcamp**; `--probe` in preflight catches an unavailable version |
| Embedding model | `text-embedding-3-large` `1`, `GlobalStandard`, 20k TPM, 3072 dims |
| Python pins | see `requirements.txt` (azure-ai-projects 2.7.0, azure-search-documents 12.0.0, openai 3.22.1, …) |
| Chat/embeddings endpoint | `AZURE_OPENAI_ENDPOINT` = `https://<account>.openai.azure.com/` (Bicep output `openAiEndpoint`). The Foundry *project* endpoint serves the Agent/Responses surface only — `get_openai_client()` on it 404s on embeddings (Azure/azure-sdk-for-python#44532) |

Re-verify live: `az cognitiveservices account list-models -n <acct> -g <rg>`.

> ✅ **Live-verified** (Nov 2026): a full squadron was deployed end-to-end on a
> real subscription — `rg-corbit-sq90` in `spaincentral` — and every lab path
> ran: connection test, indexing, grounded Q&A, blackbox forensics, multimodal
> assessment, remediation generation, agent loop + tools, incident simulator,
> vulnerable/hardened duel, the Foundry backend stretch, and the containers
> track (all endpoints). Verified on **Windows Git Bash**; expect ~10–15 min
> of data-plane RBAC propagation after `--assign-roles` (Storage/Search
> typically land before Cognitive Services).
>
> **Model note**: the test subscription had no `gpt-4.1` `GlobalStandard`
> quota in *any* region (only Batch SKUs). The deployment used
> `gpt-4o` `2024-11-20` via
> `setup-squadron.sh --chat-model gpt-4o --chat-version 2024-11-20` — a proven
> fallback when preflight shows no `GlobalStandard.gpt-4.1` headroom. Check
> `preflight-trainer.sh` output before each event and pass `--chat-model`/
> `--chat-version` accordingly.

## Manual steps (subscription admin)

1. Register providers if needed: `az provider register -n Microsoft.CognitiveServices` (also `Microsoft.Search`, `Microsoft.Storage`, `Microsoft.KeyVault`).
2. Grant **per-RG Contributor + the six data-plane roles** to each
   participant — use `trainer/assign-squadron-access.sh` (see Trainer Zone).
3. If `members.csv` e-mail resolution fails (no directory-read rights), either
   request *Directory Readers* or have members self-resolve via
   `az ad signed-in-user show --query id -o tsv` and use GUIDs instead —
   `preflight-trainer.sh --check-entra-email` tests this ahead of time.
4. Quota: preflight flags insufficient model TPM / Search service count as
   `BLOCKING:` — file quota increases via the portal early; they take time.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `CredentialUnavailableError` / 401 | not logged in / wrong tenant | `az login --tenant <id>`; `az account show` |
| 403 on AI or Search calls | missing data-plane roles | ask the **trainer** — only they can assign (`trainer/assign-squadron-access.sh`); check `az role assignment list` on your RG |
| 401 right after deploy, roles confirmed assigned | RBAC propagation lag (measured: ~10–15 min; Cognitive Services slowest) | wait and retry; verify Storage first — it typically propagates earlier |
| name conflict on redeploy after teardown | Key Vault / AIServices still soft-deleted | trainer: `teardown-all.sh --purge`, or pass `--name-seed` |
| `StorageAccountAlreadyTaken` | global DNS collision (hash reduces, never guarantees) | re-run `setup-squadron.sh --name-seed <rand>` |
| `semantic ranker` errors mid-lab | free-plan monthly quota exhausted | set `semanticSearchPlan=standard` (billed) or run queries with `--no-semantic` |
| embedding dimension error | wrong `EXPECTED_EMBEDDING_DIMS` or model | `.env` `EXPECTED_EMBEDDING_DIMS` must match the deployed model (3072 for 3-large) |
| model deployment failed | region capacity/quota | `trainer/preflight-trainer.sh`; retry with `--location`; if `GlobalStandard.gpt-4.1` is absent subscription-wide, use `--chat-model gpt-4o --chat-version 2024-11-20` |
| `.env` missing/incomplete | setup not run or partial deploy | re-run `setup-squadron.sh` — Bicep is idempotent |
| `az ad user show` fails | no directory-read rights | use GUIDs or `az ad signed-in-user show` self-resolution |

## Verification without Azure

```bash
pip install -r requirements.txt
pytest tests/ -v                       # fixture tests + shell-logic regression tests
ruff check day1 day2 day3 common tests # lint
az bicep build --file day1/infra/main.bicep   # in devcontainer/CI
shellcheck scripts/*.sh scripts/lib/*.sh trainer/*.sh
```

CI (`azure-pipelines.yml`) runs all of the above — it **never deploys**;
deployment is always a human decision. On Azure Repos, PR enforcement comes
from the branch policy's build validation, not from the YAML.

## Known limitations (documented, not bugs)

- **Live-verified**: `AZURE_OPENAI_ENDPOINT` chat/embedding routes, the
  preflight quota magnitudes, deploy→teardown→purge, and all lab paths were
  proven on a real subscription (see the ✅ note above). Subscription-specific
  variation still exists — model quota differs per subscription, so always
  re-run `preflight-trainer.sh` before an event.
- `ms-vscode.azure-account` is deprecated and deliberately not recommended;
  Entra auth flows through `az login` anyway.
- Session recordings are produced per delivery by the trainer — the repo
  cannot guarantee per-step timestamps; treat lab-guide checkpoint blocks as
  the reliable reference.
- The e-mail → object-ID resolution in `members.csv` needs directory-read
  rights; the GUID path (`az ad signed-in-user show`) is the no-rights
  fallback — this is a tenant limitation, not a script gap.
- `preflight-trainer.sh` needs a working `python3`/`python` for quota
  parsing; on Windows Git Bash a Store-stub `python3` is auto-skipped.
