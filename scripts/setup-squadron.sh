#!/usr/bin/env bash
# =============================================================================
# Project Critical Orbit — setup-squadron.sh
#
# Participant-safe provisioning script. Deploys ONE squadron's lab stack into
# its own resource group (rg-corbit-sq<NN>) and writes a local .env file with
# endpoints/identifiers ONLY (no secrets — all auth is via `az login` / Entra).
#
# Usage:
#   ./setup-squadron.sh                      # interactive: prompts for team no.
#   ./setup-squadron.sh --team 7
#   ./setup-squadron.sh --team 7 --location swedencentral \
#       --members-file members.csv --yes
#   ./setup-squadron.sh --help
#
# Options:
#   --team N              Squadron number 1-99 (prompted if omitted).
#   --location REGION     Azure region (default: swedencentral).
#   --members-file CSV    CSV of `team,identity` rows. `identity` may be an
#                         Entra e-mail (resolved via `az ad user show`) or a
#                         raw object ID. Only rows for this squadron are used.
#   --member-object-ids   Comma-separated Entra object IDs (GUIDs). Use when
#                         directory-read rights are unavailable. May be
#                         repeated/combined with --members-file.
#   --name-seed STRING    Perturb deterministic names on DNS-name collision.
#   --yes                 Skip the pre-deploy confirmation prompt.
#   -h, --help            Show this help.
#
# This script can ONLY act on rg-corbit-sq<NN> for the team number you provide.
# It never targets other teams' resource groups.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BICEP_FILE="${REPO_ROOT}/day1/infra/main.bicep"
ENV_FILE="${REPO_ROOT}/.env"

DEFAULT_LOCATION="swedencentral"
RG_PREFIX="rg-corbit-sq"

TEAM="" LOCATION="$DEFAULT_LOCATION" MEMBERS_FILE="" NAME_SEED="" ASSUME_YES=0
MEMBER_OIDS_RAW=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | head -n -1; exit "${1:-0}"; }

# ---------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)               TEAM="${2:?--team needs a value}"; shift 2 ;;
    --location)           LOCATION="${2:?--location needs a value}"; shift 2 ;;
    --members-file)       MEMBERS_FILE="${2:?--members-file needs a value}"; shift 2 ;;
    --member-object-ids)  MEMBER_OIDS_RAW="${MEMBER_OIDS_RAW:+${MEMBER_OIDS_RAW},}${2:?needs value}"; shift 2 ;;
    --name-seed)          NAME_SEED="${2:?--name-seed needs a value}"; shift 2 ;;
    --yes|-y)             ASSUME_YES=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# -------------------------------------------------------------- prerequisites --
for tool in az jq; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found. Install it first (see README prerequisites)."
done
[[ -f "$BICEP_FILE" ]] || die "Bicep template not found: $BICEP_FILE"

if ! az bicep version >/dev/null 2>&1; then
  info "Bicep CLI not found — installing via 'az bicep install'..."
  az bicep install || die "Failed to install Bicep CLI."
fi

az account show >/dev/null 2>&1 || die "Not signed in. Run 'az login' (use --tenant if you belong to multiple tenants), then retry."

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
info "Subscription: $SUBSCRIPTION_ID | Tenant: $TENANT_ID"

# ------------------------------------------------------------ team selection --
if [[ -z "$TEAM" ]]; then
  read -r -p "Squadron number (1-99): " TEAM
fi
[[ "$TEAM" =~ ^[0-9]+$ ]] || die "Team number must be an integer, got '$TEAM'."
(( TEAM >= 1 && TEAM <= 99 )) || die "Team number must be between 1 and 99."
TEAM_ID="$(printf '%02d' "$TEAM")"
RG_NAME="${RG_PREFIX}${TEAM_ID}"
info "Squadron: ${TEAM_ID}  ->  resource group: ${RG_NAME}  region: ${LOCATION}"

# Safety rail: refuse to operate on anything outside the naming convention.
[[ "$RG_NAME" =~ ^rg-corbit-sq[0-9]{2}$ ]] || die "Internal error: RG name '$RG_NAME' violates convention."

# ------------------------------------------------------- member object IDs --
GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
declare -A OIDS=()

# The deployer always gets access.
DEPLOYER_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -z "$DEPLOYER_OID" ]]; then
  warn "Could not resolve your own object ID (az ad signed-in-user show)."
  warn "This can happen for service principals or restricted tenants."
  warn "If deployment RBAC fails, pass --member-object-ids <your-object-id>."
else
  OIDS["$DEPLOYER_OID"]=1
  info "Deployer object ID: $DEPLOYER_OID"
fi

resolve_member() {
  local ident="$1"
  if [[ "$ident" =~ $GUID_RE ]]; then
    OIDS["$ident"]=1; return 0
  fi
  local oid
  if oid="$(az ad user show --id "$ident" --query id -o tsv 2>/dev/null)"; then
    OIDS["$oid"]=1
    info "  resolved $ident -> $oid"
  else
    warn "  could not resolve '$ident' via 'az ad user show'."
    warn "  If you lack directory-read rights, ask the member to run:"
    warn "    az ad signed-in-user show --query id -o tsv"
    warn "  and put that GUID in the CSV (or pass --member-object-ids)."
  fi
}

if [[ -n "$MEMBERS_FILE" ]]; then
  [[ -f "$MEMBERS_FILE" ]] || die "Members file not found: $MEMBERS_FILE"
  info "Resolving squadron members from $MEMBERS_FILE ..."
  while IFS=, read -r row_team row_ident; do
    row_team="${row_team//[$'\r\n ']/}"; row_ident="${row_ident//[$'\r\n ']/}"
    [[ -z "$row_team" || "${row_team:0:1}" == "#" ]] && continue
    [[ "$row_team" == "team" ]] && continue  # header row
    [[ "$(printf '%02d' "$row_team" 2>/dev/null || echo xx)" == "$TEAM_ID" ]] || continue
    [[ -n "$row_ident" ]] && resolve_member "$row_ident"
  done < "$MEMBERS_FILE"
fi

if [[ -n "$MEMBER_OIDS_RAW" ]]; then
  IFS=',' read -r -a extra <<< "$MEMBER_OIDS_RAW"
  for oid in "${extra[@]}"; do
    oid="${oid//[[:space:]]/}"
    [[ "$oid" =~ $GUID_RE ]] || die "--member-object-ids expects GUIDs, got '$oid'."
    OIDS["$oid"]=1
  done
fi

# ---------------------------------------------------------------- create RG --
info "Ensuring resource group $RG_NAME exists ..."
az group create --name "$RG_NAME" --location "$LOCATION" \
  --tags bootcamp=critical-orbit "squadron=${TEAM_ID}" --output none
ok "Resource group ready."

# -------------------------------------------------- name collision preflight --
# Bicep derives names via uniqueString(), whose hash is opaque — we cannot
# predict the final name locally, so we validate the deployment with what-if
# instead. If a globally-unique name still collides at deploy time, the ARM
# error (e.g. StorageAccountAlreadyTaken) is surfaced with --name-seed retry
# guidance in the failure handler below.
OIDS_JSON="$({ printf '%s\n' "${!OIDS[@]:-}"; } | jq -R . | jq -cs 'map(select(length>0))')"
info "Running deployment what-if (preflight validation, no changes) ..."
WHATIF_ERR="$(mktemp)"
if ! az deployment group what-if \
    --resource-group "$RG_NAME" \
    --template-file "$BICEP_FILE" \
    --parameters "teamNumber=${TEAM}" "location=${LOCATION}" \
      "principalObjectIds=${OIDS_JSON}" \
      ${NAME_SEED:+nameSeed="$NAME_SEED"} \
    --no-pretty-print --output none 2>"$WHATIF_ERR"; then
  cat "$WHATIF_ERR" >&2
  warn "What-if reported problems — the deployment may still work, but watch"
  warn "the output. If names collide, retry with --name-seed <random-string>."
fi
rm -f "$WHATIF_ERR"

# ------------------------------------------------------------------- deploy --
ok "Principals to receive lab access: $(echo "$OIDS_JSON" | jq length)"

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Deploy squadron ${TEAM_ID} infrastructure to ${RG_NAME} in ${LOCATION}? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Aborted by user."
fi

DEPLOY_NAME="corbit-sq${TEAM_ID}-$(date +%Y%m%d%H%M%S)"
info "Deploying Bicep ($DEPLOY_NAME) — this takes a few minutes ..."
if ! az deployment group create \
    --resource-group "$RG_NAME" \
    --name "$DEPLOY_NAME" \
    --template-file "$BICEP_FILE" \
    --parameters "teamNumber=${TEAM}" "location=${LOCATION}" \
      "principalObjectIds=${OIDS_JSON}" ${NAME_SEED:+"nameSeed=${NAME_SEED}"} \
    --output none; then
  warn "Deployment failed. Common causes:"
  warn "  * Storage/KV/Search name collision  -> retry with --name-seed <rand>"
  warn "  * Model/quota unavailable in region -> run trainer/preflight-trainer.sh"
  warn "Inspect details:"
  warn "  az deployment group show -g $RG_NAME -n $DEPLOY_NAME --query properties.error"
  exit 1
fi
ok "Deployment succeeded."

# ------------------------------------------------------------------ outputs --
info "Writing ${ENV_FILE} (endpoints/identifiers only — no secrets) ..."
OUT="$(az deployment group show -g "$RG_NAME" -n "$DEPLOY_NAME" --query properties.outputs)"

get() { echo "$OUT" | jq -r ".$1.value // empty"; }

umask 077
cat > "$ENV_FILE" <<EOF
# Project Critical Orbit — squadron ${TEAM_ID}
# Generated by scripts/setup-squadron.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains endpoints/identifiers only. NO secrets (auth = Entra / az login).
TEAM_ID=${TEAM_ID}
AZURE_RESOURCE_GROUP=$(get resourceGroupName)
AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
AZURE_LOCATION=${LOCATION}

FOUNDRY_PROJECT_ENDPOINT=$(get foundryProjectEndpoint)
FOUNDRY_PROJECT_NAME=$(get foundryProjectName)
AZURE_AI_ENDPOINT=$(get aiServicesEndpoint)

CHAT_MODEL_DEPLOYMENT=$(get chatModelDeployment)
EMBEDDING_MODEL_DEPLOYMENT=$(get embeddingModelDeployment)
EXPECTED_EMBEDDING_DIMS=3072

AZURE_SEARCH_ENDPOINT=$(get searchEndpoint)
AZURE_SEARCH_INDEX_NAME=flight-manuals

STORAGE_ACCOUNT_NAME=$(get storageAccountName)
STORAGE_CONTAINER_NAME=$(get storageContainerName)
KEY_VAULT_NAME=$(get keyVaultName)

# Day 3 safety switch — trainer-controlled only.
ENABLE_WRITE_TOOLS=false
EOF
chmod 600 "$ENV_FILE" 2>/dev/null || true
ok ".env written (mode 600)."

cat <<EOF

============================================================
 Squadron ${TEAM_ID} is GO for launch.
 Next: cd day1 && python src/01_test_connection.py
============================================================
EOF
