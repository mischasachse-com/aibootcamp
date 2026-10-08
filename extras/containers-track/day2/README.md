# Containers Track — Day 2: the Blackbox Investigation as a container API

The full Day 2 forensic pipeline behind HTTP:

| Endpoint | Wraps | Azure credentials? |
|---|---|---|
| `GET /health` | — | no |
| `POST /parse` | `01_parse_blackbox.py` — tolerant JSON repair + anomaly detection + NSG audit | **no** |
| `POST /assess` | `02_multimodal_analysis.py` — analysis JSON + topology PNG → schema-validated `MissionAssessment` | yes |
| `POST /remediation` | `03_generate_remediation_bicep.py` — AI-drafted NSG fix | yes |

`POST /assess` accepts an optional body `{"analysis": {...}}` (a previous
`/parse` result); without it, the parse step runs first.
`POST /remediation` returns `{"bicep": "...", "warning": "UNTRUSTED — NEVER
AUTO-DEPLOY", "flagged_rules": [...]}` — same untrusted-output boundary as
the lab; nothing is ever written to `day1/infra/` or deployed.

## Golden rule

Confirm the Day 1 container works first — Day 2 uses the same Azure stack
(AI Services account + `gpt-4.1` deployment) and the same image pattern.

## Prerequisites

- Containers Track Day 1 done; squadron stack still deployed; `az login` active
- Docker running

## Data files (decision: COPY into the image)

The pipeline reads `data/blackbox/` (telemetry, NSG export, topology PNG).
The shared Dockerfile **COPYs `data/` into the image at `/app/data`** —
chosen over a volume mount because it is static, simple, and always present
in a timed lab. Env vars (`BLACKBOX_DATA_PATH`, `NSG_EXPORT_PATH`,
`TOPOLOGY_IMAGE_PATH`) point at those baked-in paths by default.

Prefer live files instead? Mount the repo's data dir read-only and repoint:

```bash
docker run --rm -p 8000:8000 \
  -v "$(pwd)/data:/app/data-mnt:ro" \
  -e BLACKBOX_DATA_PATH=/app/data-mnt/blackbox/telemetry_dump_corrupted.json \
  -e NSG_EXPORT_PATH=/app/data-mnt/blackbox/nsg_export_ground_station.json \
  -e TOPOLOGY_IMAGE_PATH=/app/data-mnt/blackbox/orbital_mesh_topology.png \
  corbit-track-day2
```

## Build (from the repo root)

```bash
docker build -f extras/containers-track/shared/Dockerfile \
    --build-arg DAY=day2 -t corbit-track-day2 .
```

## Run locally

```bash
docker run --rm -p 8000:8000 corbit-track-day2

curl http://localhost:8000/health     # -> {"status":"ok"}
curl -s http://localhost:8000/parse -X POST   # pure Python — works anywhere
```

`/assess` and `/remediation` need a credential — run the app with `uvicorn`
outside Docker (same as Day 1) or deploy to ACA:

```bash
cd extras/containers-track/day2 && uvicorn app.main:app --port 8000

# pipeline flow: parse once, then assess with that result
curl -s http://localhost:8000/parse -X POST > analysis.json
curl -s http://localhost:8000/assess -X POST \
  -H 'Content-Type: application/json' -d "{\"analysis\": $(cat analysis.json)}"
curl -s http://localhost:8000/remediation -X POST | python -c "import sys,json;print(json.load(sys.stdin)['bicep'])"
```

## Deploy to Azure Container Apps

Same script as Day 1 — only `--day` and the image tag change:

```bash
extras/containers-track/shared/deploy/deploy-container-app.sh --team <NN> --day day2
```

No extra env vars vs Day 1 (data files are baked into the image). The managed
identity needs the same two roles — the deploy script assigns them (or prints
the commands for your team lead); no new roles are required.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `404` "telemetry file not found" | `BLACKBOX_DATA_PATH` wrong, or the mount didn't land — check the path inside the container |
| `422`/validation error on `/assess` | model drifted from the `MissionAssessment` schema — that's the lab's point; retry or re-run `/parse` |
| `401`/`403` on `/assess`, `/remediation` | credential/RBAC — same remediation as Day 1 |
| empty `bicep` + detail note | no flagged rules — the NSG export genuinely passed the audit |

## Support

Container questions → **Containers team lead** · AI pipeline questions →
**bootcamp trainer**.

## Tested / untested

- ✅ verified: image build, `/health` 200, `/parse` returns the real analysis
  dict (no credentials needed), non-root, no secrets in layers
- ⏳ untested here: `/assess`, `/remediation`, ACA deploy (needs live Azure)
