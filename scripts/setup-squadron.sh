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
#       --members-file members.csv --assign-roles --yes
#   ./setup-squadron.sh --help
#
# Options:
#   --team N              Squadron number 1-99, leading zero optional
#                         (prompted if omitted).
#   --location REGION     Azure region (default: swedencentral).
#   --assign-roles        Create data-plane role assignments inside the Bicep
#                         deployment. OFF by default: this requires
#                         roleAssignments/write, which plain Contributor lacks.
#                         The normal flow is that the TRAINER pre-assigns the
#                         data-plane roles per squadron (see
#                         trainer/assign-squadron-access.sh). Only use this flag
#                         when the deploying identity has those rights.
#   --members-file CSV    CSV of `team,identity[,type]` rows used ONLY with
#                         --assign-roles. `identity` may be an Entra e-mail
#                         (resolved via `az ad user show`) or a raw object ID;
#                         optional `type` is User|Group|ServicePrincipal
#                         (default User). Only rows for this squadron are used.
#   --member-object-ids   Comma-separated Entra object IDs, optionally with a
#                         :Type suffix (GUID:Group). Use with --assign-roles
#                         when directory-read rights are unavailable.
#   --name-seed STRING    Perturb deterministic names on DNS-name collision.
#   --yes                 Skip the pre-deploy confirmation prompt.
#   -h, --help            Show this help.
#
# This script can ONLY act on rg-corbit-sq<NN> for the team number you provide.
# It never targets other teams' resource groups.
# =============================================================================
# shellcheck disable=SC2034  # PRINCIPALS is read via a nameref in corbit_principals_json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BICEP_FILE="${REPO_ROOT}/day1/infra/main.bicep"
ENV_FILE="${REPO_ROOT}/.env"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DEFAULT_LOCATION="swedencentral"
RG_PREFIX="rg-corbit-sq"

TEAM="" LOCATION="$DEFAULT_LOCATION" MEMBERS_FILE="" NAME_SEED="" ASSUME_YES=0
ASSIGN_ROLES=0 MEMBER_OIDS_RAW=""

usage() { corbit_usage "$0" "${1:-0}"; }

# ---------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)               TEAM="${2:?--team needs a value}"; shift 2 ;;
    --location)           LOCATION="${2:?--location needs a value}"; shift 2 ;;
    --assign-roles)       ASSIGN_ROLES=1; shift ;;
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
  command -v "$tool" >/dev/null 2>&1 || corbit_die "'$tool' not found. Install it first (see README prerequisites)."
done
[[ -f "$BICEP_FILE" ]] || corbit_die "Bicep template not found: $BICEP_FILE"

if ! az bicep version >/dev/null 2>&1; then
  corbit_info "Bicep CLI not found — installing via 'az bicep install'..."
  az bicep install || corbit_die "Failed to install Bicep CLI."
fi

az account show >/dev/null 2>&1 || corbit_die "Not signed in. Run 'az login' (use --tenant if you belong to multiple tenants), then retry."

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
corbit_info "Subscription: $SUBSCRIPTION_ID | Tenant: $TENANT_ID"

# ------------------------------------------------------------ team selection --
if [[ -z "$TEAM" ]]; then
  read -r -p "Squadron number (1-99): " TEAM
fi
TEAM_ID="$(corbit_team_id "$TEAM")" \
  || corbit_die "Team number must be an integer between 1 and 99, got '$TEAM'."
TEAM_NUM=$((10#${TEAM_ID}))
RG_NAME="${RG_PREFIX}${TEAM_ID}"
corbit_info "Squadron: ${TEAM_ID}  ->  resource group: ${RG_NAME}  region: ${LOCATION}"

# Safety rail: refuse to operate on anything outside the naming convention.
corbit_assert_rg_convention "$RG_NAME"

# ------------------------------------------------------- member object IDs --
declare -A PRINCIPALS=()   # objectId -> principalType (read via nameref in corbit_principals_json)

if [[ "$ASSIGN_ROLES" -eq 1 ]]; then
  # The deployer always gets access when the script creates role assignments.
  DEPLOYER_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$DEPLOYER_OID" ]]; then
    corbit_warn "Could not resolve your own object ID (az ad signed-in-user show)."
    corbit_warn "This can happen for service principals or restricted tenants."
    corbit_warn "Pass --member-object-ids <your-object-id>:<type> to include yourself."
  else
    PRINCIPALS["$DEPLOYER_OID"]=User
    corbit_info "Deployer object ID: $DEPLOYER_OID"
  fi

  resolve_member() {
    local ident="$1" ptype="$2"
    if [[ "$ident" =~ $CORBIT_GUID_RE ]]; then
      PRINCIPALS["$ident"]="$ptype"; return 0
    fi
    if [[ "$ptype" != "User" ]]; then
      corbit_warn "  '$ident' is not a GUID and is typed '$ptype' — only user"
      corbit_warn "  e-mails can be resolved. Pass the object ID instead."
      return 0
    fi
    local oid
    if oid="$(az ad user show --id "$ident" --query id -o tsv 2>/dev/null)"; then
      PRINCIPALS["$oid"]=User
      corbit_info "  resolved $ident -> $oid"
    else
      corbit_warn "  could not resolve '$ident' via 'az ad user show'."
      corbit_warn "  If you lack directory-read rights, ask the member to run:"
      corbit_warn "    az ad signed-in-user show --query id -o tsv"
      corbit_warn "  and put that GUID in the CSV (or pass --member-object-ids)."
    fi
  }

  if [[ -n "$MEMBERS_FILE" ]]; then
    [[ -f "$MEMBERS_FILE" ]] || corbit_die "Members file not found: $MEMBERS_FILE"
    corbit_info "Resolving squadron members from $MEMBERS_FILE ..."
    while IFS=$'\t' read -r ident ptype; do
      resolve_member "$ident" "$ptype"
    done < <(corbit_parse_members "$MEMBERS_FILE" "$TEAM_ID")
  fi

  if [[ -n "$MEMBER_OIDS_RAW" ]]; then
    IFS=',' read -r -a extra <<< "$MEMBER_OIDS_RAW"
    for entry in "${extra[@]}"; do
      entry="${entry//[[:space:]]/}"
      oid="${entry%%:*}"; ptype="${entry#*:}"
      [[ "$entry" == *:* ]] || ptype="User"
      [[ "$oid" =~ $CORBIT_GUID_RE ]] || corbit_die "--member-object-ids expects GUIDs (optionally :Type), got '$entry'."
      [[ "$ptype" =~ $CORBIT_PRINCIPAL_TYPES_RE ]] || corbit_die "Invalid principal type in '$entry' (User|Group|ServicePrincipal)."
      PRINCIPALS["$oid"]="$ptype"
    done
  fi
elif [[ -n "$MEMBERS_FILE" || -n "$MEMBER_OIDS_RAW" ]]; then
  corbit_warn "--members-file/--member-object-ids are only used with --assign-roles."
  corbit_warn "By default the trainer pre-assigns data-plane roles; these arguments are ignored."
fi

# ---------------------------------------------------------------- create RG --
corbit_info "Ensuring resource group $RG_NAME exists ..."
az group create --name "$RG_NAME" --location "$LOCATION" \
  --tags bootcamp=critical-orbit "squadron=${TEAM_ID}" --output none
corbit_ok "Resource group ready."

# -------------------------------------------------- name collision preflight --
# Bicep derives names via uniqueString(), whose hash is opaque — we cannot
# predict the final name locally, so we validate the deployment with what-if
# instead. If a globally-unique name still collides at deploy time, the ARM
# error (e.g. StorageAccountAlreadyTaken) is surfaced with --name-seed retry
# guidance in the failure handler below.
PRINCIPALS_JSON="$(corbit_principals_json PRINCIPALS)"
corbit_info "Running deployment what-if (preflight validation, no changes) ..."
WHATIF_ERR="$(mktemp)"
if ! az deployment group what-if \
    --resource-group "$RG_NAME" \
    --template-file "$BICEP_FILE" \
    --parameters "teamNumber=${TEAM_NUM}" "location=${LOCATION}" \
      "assignDataPlaneRoles=${ASSIGN_ROLES}" "principals=${PRINCIPALS_JSON}" \
      ${NAME_SEED:+nameSeed="$NAME_SEED"} \
    --no-pretty-print --output none 2>"$WHATIF_ERR"; then
  cat "$WHATIF_ERR" >&2
  corbit_warn "What-if reported problems — the deployment may still work, but watch"
  corbit_warn "the output. If names collide, retry with --name-seed <random-string>."
fi
rm -f "$WHATIF_ERR"

# ------------------------------------------------------------------- deploy --
if [[ "$ASSIGN_ROLES" -eq 1 ]]; then
  corbit_ok "Role assignments: ENABLED — $(echo "$PRINCIPALS_JSON" | jq length) principal(s) will receive data-plane roles."
else
  corbit_info "Role assignments: OFF (default) — the trainer pre-assigns data-plane"
  corbit_info "roles via trainer/assign-squadron-access.sh. Verify yours with:"
  corbit_info "  az role assignment list -g $RG_NAME --assignee \$(az ad signed-in-user show --query id -o tsv) -o table"
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Deploy squadron ${TEAM_ID} infrastructure to ${RG_NAME} in ${LOCATION}? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || corbit_die "Aborted by user."
fi

DEPLOY_NAME="corbit-sq${TEAM_ID}-$(date +%Y%m%d%H%M%S)"
corbit_info "Deploying Bicep ($DEPLOY_NAME) — this takes a few minutes ..."
if ! az deployment group create \
    --resource-group "$RG_NAME" \
    --name "$DEPLOY_NAME" \
    --template-file "$BICEP_FILE" \
    --parameters "teamNumber=${TEAM_NUM}" "location=${LOCATION}" \
      "assignDataPlaneRoles=${ASSIGN_ROLES}" "principals=${PRINCIPALS_JSON}" \
      ${NAME_SEED:+"nameSeed=${NAME_SEED}"} \
    --output none; then
  corbit_warn "Deployment failed. Common causes:"
  corbit_warn "  * Storage/KV/Search name collision  -> retry with --name-seed <rand>"
  corbit_warn "  * Model/quota unavailable in region -> run trainer/preflight-trainer.sh"
  corbit_warn "  * soft-deleted name conflict after a teardown -> run trainer/teardown-all.sh --purge"
  corbit_warn "Inspect details:"
  corbit_warn "  az deployment group show -g $RG_NAME -n $DEPLOY_NAME --query properties.error"
  exit 1
fi
corbit_ok "Deployment succeeded."

# ------------------------------------------------------------------ outputs --
corbit_info "Writing ${ENV_FILE} (endpoints/identifiers only — no secrets) ..."
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
# OpenAI data-plane endpoint for chat/embeddings (the Foundry project endpoint
# is only for the Agent Service backend — see README "Verified versions").
AZURE_OPENAI_ENDPOINT=$(get openAiEndpoint)

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
corbit_ok ".env written (mode 600)."

cat <<EOF

============================================================
 Squadron ${TEAM_ID} is GO for launch.
 Next: cd day1 && python src/01_test_connection.py
============================================================
EOF
