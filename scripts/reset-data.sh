#!/usr/bin/env bash
# =============================================================================
# Project Critical Orbit — reset-data.sh
#
# Resets THIS squadron's lab data between lessons WITHOUT touching the
# deployed infrastructure:
#   * deletes the Azure AI Search index (rebuilt by day1/02_index_flight_manuals.py)
#   * purges blobs in the squadron's lab-data container
#   * removes local generated artifacts (day2/generated, day3 audit log)
#
# SAFETY: this script refuses to run against anything that does not match the
# squadron naming convention. It reads resource names from the local .env
# written by setup-squadron.sh and re-derives them from the resource group —
# it can never target another team's resources.
#
# Usage:
#   ./reset-data.sh [--team N] [--yes] [--help]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

TEAM="" ASSUME_YES=0
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | head -n -1; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)     TEAM="${2:?--team needs a value}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for tool in az jq; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found."
done
az account show >/dev/null 2>&1 || die "Not signed in. Run 'az login' first."

# Resolve squadron context: prefer .env, fall back to --team.
RG_NAME="" SEARCH_NAME="" SEARCH_ENDPOINT="" SA_NAME="" CONTAINER="lab-data" INDEX_NAME="flight-manuals"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  RG_NAME="${AZURE_RESOURCE_GROUP:-}"
  SEARCH_ENDPOINT="${AZURE_SEARCH_ENDPOINT:-}"
  INDEX_NAME="${AZURE_SEARCH_INDEX_NAME:-flight-manuals}"
  SA_NAME="${STORAGE_ACCOUNT_NAME:-}"
  CONTAINER="${STORAGE_CONTAINER_NAME:-lab-data}"
fi

if [[ -z "$RG_NAME" && -n "$TEAM" ]]; then
  [[ "$TEAM" =~ ^[0-9]+$ ]] && (( TEAM >= 1 && TEAM <= 99 )) || die "Invalid --team '$TEAM'."
  RG_NAME="rg-corbit-sq$(printf '%02d' "$TEAM")"
fi
[[ -n "$RG_NAME" ]] || die "No .env found and no --team given. Run setup-squadron.sh first or pass --team N."

# Convention check — never act on a foreign resource group.
[[ "$RG_NAME" =~ ^rg-corbit-sq[0-9]{2}$ ]] \
  || die "Refusing: '$RG_NAME' does not match the squadron RG convention rg-corbit-sq<NN>."

az group show -n "$RG_NAME" >/dev/null 2>&1 || die "Resource group '$RG_NAME' not found in this subscription."

# Derive names from the RG itself when .env is missing them (no trust in .env
# beyond identifiers — everything is re-verified against the RG anyway).
if [[ -z "$SEARCH_NAME" ]]; then
  if [[ -n "$SEARCH_ENDPOINT" ]]; then
    SEARCH_NAME="${SEARCH_ENDPOINT#https://}"; SEARCH_NAME="${SEARCH_NAME%%.*}"
  else
    SEARCH_NAME="$(az resource list -g "$RG_NAME" --resource-type Microsoft.Search/searchServices --query '[0].name' -o tsv)"
  fi
fi
if [[ -z "$SA_NAME" ]]; then
  SA_NAME="$(az resource list -g "$RG_NAME" --resource-type Microsoft.Storage/storageAccounts --query '[0].name' -o tsv)"
fi
[[ -n "$SEARCH_NAME" && -n "$SA_NAME" ]] || die "Could not resolve Search/Storage resources inside $RG_NAME."

cat <<EOF
Reset target (YOUR squadron only):
  Resource group : $RG_NAME
  Search service : $SEARCH_NAME  (index '$INDEX_NAME' will be deleted)
  Storage        : $SA_NAME      (container '$CONTAINER' will be emptied)
  Local          : day2/generated/, day3/audit_log.jsonl will be removed
EOF

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Proceed with reset? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Aborted."
fi

# --- Delete the Search index (control-plane name verified inside our RG) ------
info "Deleting search index '$INDEX_NAME' on '$SEARCH_NAME' (ok if absent) ..."
az rest --method delete \
  --url "https://${SEARCH_NAME}.search.windows.net/indexes/${INDEX_NAME}?api-version=2025-09-01" \
  >/dev/null 2>&1 && ok "Index deleted." || warn "Index not deleted (may not exist yet — fine)."

# --- Empty the lab-data container ---------------------------------------------
info "Purging blobs in ${SA_NAME}/${CONTAINER} ..."
if az storage blob delete-batch \
    --account-name "$SA_NAME" \
    --source "$CONTAINER" \
    --auth-mode login --output none 2>/dev/null; then
  ok "Container emptied."
else
  warn "Blob purge skipped (container may be empty or missing)."
fi

# --- Local generated artifacts ------------------------------------------------
rm -rf "${REPO_ROOT}/day2/generated"
rm -f "${REPO_ROOT}/day3/audit_log.jsonl"
ok "Local generated artifacts removed."

ok "Squadron data reset complete — infrastructure untouched."
