#!/usr/bin/env bash
# =============================================================================
# Containers Track — deploy-container-app.sh
#
# ONE deployment path for every dayN app: builds the shared image in Azure
# Container Registry (remote build — no local Docker daemon needed for this
# step), then creates a Container Apps environment and a Container App with a
# user-assigned managed identity in YOUR squadron resource group.
#
# Everything lands inside rg-corbit-sq<NN> — the same RG the Day 1 lab stack
# lives in. Squadron isolation is preserved; nothing crosses subscriptions or
# resource groups.
#
# Authentication is Entra-only end-to-end:
#   * the app identity pulls the image via AcrPull (no admin user, no keys)
#   * the app calls OpenAI/Search via DefaultAzureCredential -> the managed
#     identity, with these data-plane roles:
#       - "Cognitive Services OpenAI User" on the AI Services (Foundry) account
#         https://learn.microsoft.com/azure/ai-foundry/openai/how-to/managed-identity
#       - "Search Index Data Reader" on the AI Search service
#         https://learn.microsoft.com/azure/search/search-security-rbac
#       - "AcrPull" on the Container Registry
#
# RBAC caveat: role assignment requires Microsoft.Authorization/roleAssignments/
# write, which a participant's Contributor role does NOT include (same
# constraint as the main labs). The script attempts the assignments; if they
# fail it prints the exact commands for your Containers team lead / trainer
# (who holds User Access Administrator) to run. --skip-rbac skips the step.
#
# Usage (from the repo root):
#   extras/containers-track/shared/deploy/deploy-container-app.sh --team 7 --day day1
#
# Options:
#   --team N            Squadron number (1-99). RG must exist (Day 1 stack).
#   --day dayN          Which app to deploy: day1 | day2 | day3 (default day1).
#   --image-tag TAG     Image tag (default: <day>-latest).
#   --app-name NAME     Container App name (default: ca-corbit-<day>-sq<NN>).
#   --location REGION   Region for new resources (default: RG location).
#   --env-file PATH     File with endpoints (default: repo .env, written by
#                       scripts/setup-squadron.sh). Identifiers only, no keys.
#   --skip-rbac         Skip the managed-identity role assignments.
#   -h, --help          Show this help.
#
# Re-running is safe: every step checks existence first and updates in place.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"

# az -o tsv from extension modules (e.g. `az identity`) emits CRLF on Windows;
# a captured \r corrupts resource IDs passed to later commands. Strip it.
az_tsv() { "$@" | tr -d '\r'; }

# Git Bash (MSYS2) rewrites any argument starting with '/' into a Windows path
# (C:/Program Files/Git/...), which silently corrupts ARM resource IDs passed
# to --user-assigned / --registry-identity / --scope. Disable conversion only
# for those commands — the acr-build context path below MUST keep converting.
az_np() { MSYS_NO_PATHCONV=1 az "$@"; }

TEAM="" RG="" DAY="day1" IMAGE_TAG="" APP_NAME="" LOCATION=""
ENV_FILE="${REPO_ROOT}/.env" SKIP_RBAC=0

usage() { corbit_usage "$0" "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)         TEAM="${2:?--team needs a value}"; shift 2 ;;
    --resource-group) RG="${2:?--resource-group needs a value}"; shift 2 ;;
    --day)          DAY="${2:?--day needs a value}"; shift 2 ;;
    --image-tag)    IMAGE_TAG="${2:?--image-tag needs a value}"; shift 2 ;;
    --app-name)     APP_NAME="${2:?--app-name needs a value}"; shift 2 ;;
    --location)     LOCATION="${2:?--location needs a value}"; shift 2 ;;
    --env-file)     ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    --skip-rbac)    SKIP_RBAC=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || corbit_die "'az' not found — install Azure CLI."
az account show >/dev/null 2>&1 || corbit_die "Not signed in. Run 'az login'."
SUBSCRIPTION_ID="$(az_tsv az account show --query id -o tsv)"

[[ -f "${REPO_ROOT}/extras/containers-track/${DAY}/app/main.py" ]] \
  || corbit_die "No app at extras/containers-track/${DAY}/app/ — invalid --day '${DAY}'."

# ---------------------------------------------------------------- resolve RG --
if [[ -n "${TEAM}" ]]; then
  tid="$(corbit_team_id "${TEAM}")" || corbit_die "Invalid --team '${TEAM}'."
  RG="rg-corbit-sq${tid}"
fi
[[ -n "${RG}" ]] || corbit_die "Pass --team N or --resource-group <name>."
corbit_assert_rg_convention "${RG}"
tid="${RG##*sq}"
az group show -n "${RG}" >/dev/null 2>&1 \
  || corbit_die "${RG} does not exist — run scripts/setup-squadron.sh --team ${tid} first."
LOCATION="${LOCATION:-$(az_tsv az group show -n "${RG}" --query location -o tsv)}"
IMAGE_TAG="${IMAGE_TAG:-${DAY}-latest}"
APP_NAME="${APP_NAME:-ca-corbit-${DAY}-sq${tid}}"

# Endpoints/deployments come from the squadron .env (identifiers only — no
# secrets are ever read into the image; the app authenticates via MI).
if [[ -f "${ENV_FILE}" ]]; then
  set -a; # shellcheck disable=SC1090
  . "${ENV_FILE}"; set +a
  corbit_info "Loaded endpoints from ${ENV_FILE}"
else
  corbit_warn "${ENV_FILE} not found — relying on already-exported env vars."
fi
for var in AZURE_OPENAI_ENDPOINT CHAT_MODEL_DEPLOYMENT AZURE_SEARCH_ENDPOINT; do
  [[ -n "${!var:-}" ]] || corbit_die "Missing ${var} — set it or provide --env-file (run scripts/setup-squadron.sh first)."
done

# Deterministic ACR name (5-50 chars, lowercase alnum): acrcorbit<tid><hash6>.
ACR_NAME="acrcorbit${tid}$(printf '%s' "${SUBSCRIPTION_ID}${RG}" | sha256sum | cut -c1-6)"
IDENTITY_NAME="id-${APP_NAME}"
ENV_NAME="cae-corbit-sq${tid}"
IMAGE_FQN="${ACR_NAME}.azurecr.io/${APP_NAME}:${IMAGE_TAG}"

corbit_info "Squadron RG : ${RG} (${LOCATION})"
corbit_info "Day app     : ${DAY}  ->  ${APP_NAME}:${IMAGE_TAG}"
corbit_info "ACR / env   : ${ACR_NAME} / ${ENV_NAME}"

# ------------------------------------------------------------------- ACR ------
if az acr show -n "${ACR_NAME}" -g "${RG}" >/dev/null 2>&1; then
  corbit_ok "ACR ${ACR_NAME} already exists."
else
  corbit_info "Creating ACR ${ACR_NAME} (Basic, admin user disabled) ..."
  az acr create -n "${ACR_NAME}" -g "${RG}" -l "${LOCATION}" --sku Basic \
    --admin-enabled false --output none
  corbit_ok "ACR ready."
fi

# Remote build — the Dockerfile lives in the repo; context is the repo root.
# --no-logs: on Windows the az CLI's log *streaming* crashes on non-cp1252
# build output (colorama UnicodeEncodeError) while the remote build keeps
# running. Skip the stream; the command still waits for completion.
corbit_info "Building image in ACR (context: repo root, DAY=${DAY}) ..."
az acr build --registry "${ACR_NAME}" --image "${APP_NAME}:${IMAGE_TAG}" \
  --file extras/containers-track/shared/Dockerfile \
  --build-arg "DAY=${DAY}" --no-logs "${REPO_ROOT}"
corbit_ok "Image pushed: ${IMAGE_FQN}"

# ------------------------------------------------------- managed identity ----
if az identity show -n "${IDENTITY_NAME}" -g "${RG}" >/dev/null 2>&1; then
  corbit_ok "Identity ${IDENTITY_NAME} already exists."
else
  az identity create -n "${IDENTITY_NAME}" -g "${RG}" -l "${LOCATION}" --output none
  corbit_ok "Identity ${IDENTITY_NAME} created."
fi
IDENTITY_ID="$(az_tsv az identity show -n "${IDENTITY_NAME}" -g "${RG}" --query id -o tsv)"
IDENTITY_PRINCIPAL="$(az_tsv az identity show -n "${IDENTITY_NAME}" -g "${RG}" --query principalId -o tsv)"
IDENTITY_CLIENT="$(az_tsv az identity show -n "${IDENTITY_NAME}" -g "${RG}" --query clientId -o tsv)"

# ------------------------------------------------------------ containerapp ---
az extension show --name containerapp >/dev/null 2>&1 \
  || az extension add --name containerapp --upgrade --output none

if az containerapp env show -n "${ENV_NAME}" -g "${RG}" >/dev/null 2>&1; then
  corbit_ok "Container Apps environment ${ENV_NAME} already exists."
else
  corbit_info "Creating Container Apps environment ${ENV_NAME} ..."
  az containerapp env create -n "${ENV_NAME}" -g "${RG}" -l "${LOCATION}" --output none
  corbit_ok "Environment ready."
fi

ENV_VARS=(
  "AZURE_OPENAI_ENDPOINT=${AZURE_OPENAI_ENDPOINT}"
  "AZURE_SEARCH_ENDPOINT=${AZURE_SEARCH_ENDPOINT}"
  "AZURE_SEARCH_INDEX_NAME=${AZURE_SEARCH_INDEX_NAME:-flight-manuals}"
  "CHAT_MODEL_DEPLOYMENT=${CHAT_MODEL_DEPLOYMENT}"
  "EMBEDDING_MODEL_DEPLOYMENT=${EMBEDDING_MODEL_DEPLOYMENT:-text-embedding-3-large}"
  "EXPECTED_EMBEDDING_DIMS=${EXPECTED_EMBEDDING_DIMS:-3072}"
  "AZURE_RESOURCE_GROUP=${RG}"
  "AZURE_CLIENT_ID=${IDENTITY_CLIENT}"
  "PORT=8000"
)

if az containerapp show -n "${APP_NAME}" -g "${RG}" >/dev/null 2>&1; then
  corbit_info "Updating existing Container App ${APP_NAME} ..."
  # Same tag -> no template diff -> no new revision -> old image keeps running.
  # Pin the immutable digest so every rebuild rolls out a fresh revision.
  DIGEST="$(az_tsv az acr repository show -n "${ACR_NAME}" -g "${RG}" \
    --image "${APP_NAME}:${IMAGE_TAG}" --query digest -o tsv)"
  az_np containerapp update -n "${APP_NAME}" -g "${RG}" \
    --image "${ACR_NAME}.azurecr.io/${APP_NAME}@${DIGEST}" \
    --set-env-vars "${ENV_VARS[@]}" --output none
else
  corbit_info "Creating Container App ${APP_NAME} (external ingress :8000, 0-1 replicas) ..."
  az_np containerapp create -n "${APP_NAME}" -g "${RG}" \
    --environment "${ENV_NAME}" \
    --image "${IMAGE_FQN}" \
    --user-assigned "${IDENTITY_ID}" \
    --registry-server "${ACR_NAME}.azurecr.io" \
    --registry-identity "${IDENTITY_ID}" \
    --ingress external --target-port 8000 \
    --min-replicas 0 --max-replicas 1 \
    --env-vars "${ENV_VARS[@]}" --output none
fi
corbit_ok "Container App deployed."

# ------------------------------------------------------------------ RBAC ------
# Contributor cannot create role assignments — attempts below are best-effort.
# On failure we print the exact commands for a privileged identity (team lead /
# trainer) to run. Same constraint as the main labs: participants do not
# self-assign RBAC.
assign_role() { # <role name> <resource id>
  local role="$1" scope="$2"
  if az_np role assignment create \
      --assignee-object-id "${IDENTITY_PRINCIPAL}" \
      --assignee-principal-type ServicePrincipal \
      --role "${role}" --scope "${scope}" --output none 2>/dev/null; then
    corbit_ok "Assigned '${role}' to ${IDENTITY_NAME} on ${scope##*/}"
  else
    corbit_warn "Could not assign '${role}' on ${scope}"
    corbit_warn "  -> ask your Containers team lead / trainer (roleAssignments/write) to run:"
    echo "       az role assignment create --assignee-object-id ${IDENTITY_PRINCIPAL} \\"
    echo "         --assignee-principal-type ServicePrincipal --role \"${role}\" --scope ${scope}"
  fi
}

if [[ "${SKIP_RBAC}" -eq 1 ]]; then
  corbit_info "--skip-rbac: role assignments skipped."
else
  ACR_ID="$(az_tsv az acr show -n "${ACR_NAME}" -g "${RG}" --query id -o tsv)"
  AIS_ID="$(az_tsv az resource list -g "${RG}" --resource-type Microsoft.CognitiveServices/accounts \
    --query "[?kind=='AIServices'].id | [0]" -o tsv)"
  SEARCH_ID="$(az_tsv az resource list -g "${RG}" --resource-type Microsoft.Search/searchServices \
    --query "[0].id" -o tsv)"
  assign_role "AcrPull" "${ACR_ID}"
  [[ -n "${AIS_ID}" ]] && assign_role "Cognitive Services OpenAI User" "${AIS_ID}" \
    || corbit_warn "No AIServices account found in ${RG} — assign 'Cognitive Services OpenAI User' manually."
  [[ -n "${SEARCH_ID}" ]] && assign_role "Search Index Data Reader" "${SEARCH_ID}" \
    || corbit_warn "No Search service found in ${RG} — assign 'Search Index Data Reader' manually."
fi

# -------------------------------------------------------------------- done ---
FQDN="$(az_tsv az containerapp show -n "${APP_NAME}" -g "${RG}" \
  --query properties.configuration.ingress.fqdn -o tsv)"
echo ""
echo "============================================================"
echo " ${APP_NAME} is deployed."
echo " https://${FQDN}/health   (first request may cold-start: min-replicas=0)"
echo " RBAC propagation can take a few minutes before AI calls work."
echo "============================================================"
