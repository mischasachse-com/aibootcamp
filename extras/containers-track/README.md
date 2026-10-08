# Containers Track (optional)

The same Project Critical Orbit labs — same AI payload, same Entra-only
authentication — delivered as containerized HTTP APIs instead of scripts.

```
script  →  FastAPI wrapper  →  Docker image  →  Azure Container Apps
```

This track is **optional and additive**: it lives entirely under
`extras/containers-track/` and changes nothing in the standard labs. Follow
it if your squadron joined the Containers path; otherwise ignore it.

## Golden rule

> **First get the standard lab working as a plain Python script, THEN
> containerize it.** The container is a different *delivery* of the same
> pipeline — not a substitute for understanding it. If the script fails, the
> container will fail the same way, only harder to debug.

## Prerequisites

| Requirement | Notes |
|---|---|
| Completed standard lab for the day | `.env` from `scripts/setup-squadron.sh`, Day 1 index populated, etc. |
| Docker | Docker Desktop / any Docker daemon for local build & run |
| Azure CLI + `az login` | for the Container Apps deploy step |
| Python ≥ 3.10 | only for running the app without Docker (`uvicorn`) |

Optional: `extras/containers-track/.devcontainer/` ships Python + Azure CLI +
Docker (docker-in-docker). Open the **repo root** in VS Code and pick this
devcontainer when prompted — it is scoped to this track.

## Support model

| Question about | Ask |
|---|---|
| Dockerfiles, ports, image builds, Container Apps, registries | **Containers team lead** |
| Prompts, RAG, agents, lab goals, Azure AI resources | **Bootcamp trainer** |

## Repository layout

```
extras/containers-track/
  README.md                    ← you are here
  .env.example                 ← placeholders only — identifiers, no secrets
  ROADMAP.md                   ← draft assessment behind the day2/3 designs
  .devcontainer/               ← optional, scoped to this track
  shared/
    Dockerfile                 ← one multi-stage image; --build-arg DAY=dayN
    Dockerfile.dockerignore    ← BuildKit ignore file (named per-Dockerfile)
    deploy/
      deploy-container-app.sh  ← one az-CLI path: ACR build + Container Apps
  day1/  app/ + README.md      ← grounded Q&A  → GET /health, POST /chat
  day2/  app/ + README.md      ← blackbox pipeline → /parse /assess /remediation
  day3/  app/ + README.md      ← agent loop → POST /incident, POST /simulate
```

## Days overview

| Day | Status | API |
|---|---|---|
| Day 1 | ✅ available | `POST /chat` — grounded Q&A over the flight-manuals index (wraps `day1/src/03_query_flight_manual.py`) |
| Day 2 | ✅ available | `POST /parse` · `/assess` · `/remediation` — blackbox forensics pipeline (wraps `day2/src/01–03`) |
| Day 3 | ✅ available | `POST /incident` · `/simulate` — Flight Director agent loop, manual backend (wraps `day3/src/01` + tools) |

Per-day step-by-step guides: [day1/README.md](day1/README.md),
[day2/README.md](day2/README.md), [day3/README.md](day3/README.md).

## How the image works

- **One Dockerfile for all days**: `--build-arg DAY=dayN` selects
  `extras/containers-track/dayN/app/`. Build context is the **repo root** —
  the wrappers reuse `common/`, the lab sources in `dayN/src/`, and the
  fixtures in `data/`, which are COPYed into `/app` mirroring the repo layout
  (so the labs' `REPO_ROOT` logic works untouched). Adding a `day4/` folder
  later requires **no change** in `shared/`.
- **No secrets in the image**: env vars only, supplied at `docker run` /
  deploy time. The `Dockerfile.dockerignore` keeps `.env` out of the context.
- **Auth**: `DefaultAzureCredential` — locally `az login` (see each day
  README: running the *app* locally with `uvicorn` is how you exercise the
  credential-backed endpoints; the container's own proof is `/health` and the
  credential-free endpoints). In Azure the Container App's **user-assigned
  managed identity** authenticates.

## Deploy to Azure Container Apps

One path, one script — reusable for every day:

```bash
# from the repo root — requires az login + the Day-1 squadron stack
extras/containers-track/shared/deploy/deploy-container-app.sh \
    --team <NN> --day day1
```

It creates, inside your own `rg-corbit-sq<NN>`: a Container Registry (Basic,
admin user disabled), a remote `az acr build` of the shared image, a
user-assigned managed identity, a Container Apps environment, and the
Container App (external ingress, scale-to-zero). It then attempts three
role assignments for the managed identity:

| Role | On | Why |
|---|---|---|
| `AcrPull` | the ACR | image pull without admin credentials |
| `Cognitive Services OpenAI User` | the AI Services (Foundry) account | chat + embeddings data plane ([docs](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/managed-identity)) |
| `Search Index Data Reader` | the AI Search service | index queries ([docs](https://learn.microsoft.com/azure/search/search-security-rbac)) |

> **RBAC caveat** (same as the main labs): `Contributor` on the RG does not
> include `roleAssignments/write`. If the assignments fail, the script prints
> the exact `az role assignment create` commands for your **Containers team
> lead** (or trainer) to run with elevated rights. `--skip-rbac` skips them.

Re-running the script is safe — every step checks existence first.

## Cleanup

Everything for this track lives inside your squadron RG — deleting it
removes the Day-1 lab stack **and** the containers track resources:

```bash
az group delete -n rg-corbit-sq<NN> --yes --no-wait
```

Azure AI Search Basic, Key Vault, and Container Apps environments accrue
charges while provisioned — tear down when done.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker build` can't find the Dockerfile | wrong context | run from the **repo root** with `-f extras/containers-track/shared/Dockerfile` |
| `/health` unreachable locally | port mapping | `docker run -p 8000:8000` and curl `http://localhost:8000/health` |
| 401 on `/chat` etc. in Container Apps | missing RBAC or propagation delay | check the printed role-assignment commands ran; wait a few minutes |
| 403 on AI calls in Container Apps | managed identity lacks data-plane role | assign `Cognitive Services OpenAI User` / `Search Index Data Reader` to `id-<app>` |
| Image pull failure in ACA | identity lacks `AcrPull` on the registry | run the printed `az role assignment create` for AcrPull |
| `POST /chat` returns `no context retrieved` | index not populated | run the standard lab's `02_index_flight_manuals.py` first |
| Env var typos | config drift | copy values from the repo-root `.env`; never invent endpoints |
| Wrong image in ACA | `--image-tag`/`--day` mix-up | re-run the deploy script — it updates the app in place |

## Cost note

Container Apps `min-replicas 0` scales to zero when idle; ACR Basic is cheap
but not free; the Container Apps *environment* has no dedicated cost on the
Consumption plan. The squadron RG delete above removes all of it.
