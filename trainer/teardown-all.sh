#!/usr/bin/env bash
# =============================================================================
# [TRAINER-ONLY] Project Critical Orbit — teardown-all.sh
#
# Deletes ALL squadron resource groups. Lives in trainer/ deliberately — this
# file is never referenced by participant guides.
#
# Safety guarantees:
#   * Only resource groups matching BOTH criteria are touched:
#       - name matches  rg-corbit-sq<NN>  (exact bootcamp convention)
#       - tag bootcamp=critical-orbit     (explicit bootcamp marker)
#   * The full target list is printed BEFORE any deletion.
#   * Interactive mode requires typing "DELETE" to confirm.
#   * --yes is available for trainer automation but is documented and loud.
#
# Soft-delete note (Mode B): resource names are deterministic, and Key Vault +
# AIServices accounts remain SOFT-DELETED after the RG is gone — a redeploy
# with the same squadron number then fails on name conflicts. Pass --purge to
# remove those soft-deleted resources after deletion. Purging is restricted to
# names matching the bootcamp convention (kv-corbit-*, ais-corbit-*) and asks
# for a separate confirmation.
#
# Usage:
#   ./teardown-all.sh              # list targets, prompt for confirmation
#   ./teardown-all.sh --yes        # non-interactive (trainer automation)
#   ./teardown-all.sh --purge      # also purge convention-matching soft-deleted
#                                  # Key Vaults + AIServices accounts afterwards
#   ./teardown-all.sh --purge --dry-run   # list deletions + purge candidates only
#   ./teardown-all.sh --help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"

ASSUME_YES=0 DRY_RUN=0 PURGE=0

usage() { corbit_usage "$0" "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --purge)   PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || corbit_die "'az' not found."
command -v jq >/dev/null 2>&1 || corbit_die "'jq' not found."
az account show >/dev/null 2>&1 || corbit_die "Not signed in. Run 'az login'."

corbit_info "Searching for bootcamp resource groups (name + tag match) ..."
# Name pattern AND tag must BOTH match — belt and braces against accidents.
mapfile -t TARGETS < <(
  az group list --tag bootcamp=critical-orbit \
    --query "[?starts_with(name, 'rg-corbit-sq')].name" -o tsv \
  | while IFS= read -r rg; do
      [[ "$rg" =~ $CORBIT_RG_RE ]] && printf '%s\n' "$rg"
    done
)

# ----------------------------------------------------------- purge candidates --
# Soft-deleted KV/AIServices survive RG deletion; they block name reuse in
# Mode B. Listed even when no RGs are deleted (leftovers from earlier runs).
PURGE_LINES=()
if [[ "$PURGE" -eq 1 ]]; then
  corbit_info "Searching for soft-deleted bootcamp Key Vaults + AI accounts ..."
  while IFS=$'\t' read -r name loc; do
    [[ "$name" =~ $CORBIT_SOFTDELETE_NAME_RE ]] || continue
    PURGE_LINES+=("keyvault|${name}|${loc}|")
  done < <(az keyvault list-deleted \
      --query "[].{name:name,location:properties.location}" -o tsv 2>/dev/null || true)
  while IFS=$'\t' read -r name loc rid; do
    [[ "$name" =~ $CORBIT_SOFTDELETE_NAME_RE ]] || continue
    rg="${rid#*resourceGroups/}"; rg="${rg%%/*}"
    PURGE_LINES+=("cognitive|${name}|${loc}|${rg}")
  done < <(az cognitiveservices account list-deleted \
      --query "[].{name:name,location:location,id:id}" -o tsv 2>/dev/null || true)
fi

# ----------------------------------------------------------------- report ---
echo ""
echo "=================  TARGETS FOR DELETION  ================="
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "  (none — no matching resource groups found)"
else
  printf '  %s\n' "${TARGETS[@]}"
fi
echo "=========================================================="
echo "  ${#TARGETS[@]} resource group(s) will be PERMANENTLY DELETED."
if [[ "$PURGE" -eq 1 ]]; then
  echo ""
  echo "===========  SOFT-DELETED RESOURCES TO PURGE  ============"
  if [[ ${#PURGE_LINES[@]} -eq 0 ]]; then
    echo "  (none found)"
  else
    for line in "${PURGE_LINES[@]}"; do echo "  ${line//|/  }"; done
  fi
  echo "  Purging is IRREVERSIBLE and only touches convention names"
  echo "  (kv-corbit-* / ais-corbit-*)."
  echo "=========================================================="
fi
echo ""

if [[ ${#TARGETS[@]} -eq 0 && ( "$PURGE" -ne 1 || ${#PURGE_LINES[@]} -eq 0 ) ]]; then
  corbit_info "Nothing to do."
  exit 0
fi

[[ "$DRY_RUN" -eq 1 ]] && { corbit_info "Dry-run: exiting without deleting anything."; exit 0; }

# ------------------------------------------------------------------- delete --
if [[ ${#TARGETS[@]} -gt 0 ]]; then
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Type DELETE to confirm deletion of all listed groups: " ans
    [[ "$ans" == "DELETE" ]] || corbit_die "Aborted — nothing was deleted."
  else
    echo "[!] --yes supplied: skipping interactive confirmation."
  fi

  for rg in "${TARGETS[@]}"; do
    corbit_info "Deleting $rg ..."
    if [[ "$PURGE" -eq 1 ]]; then
      az group delete --name "$rg" --yes   # wait: purge needs deletion complete
    else
      az group delete --name "$rg" --yes --no-wait
    fi
  done
fi

# -------------------------------------------------------------------- purge --
if [[ "$PURGE" -eq 1 && ${#PURGE_LINES[@]} -gt 0 ]]; then
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Type PURGE to permanently remove the listed soft-deleted resources: " ans
    [[ "$ans" == "PURGE" ]] || corbit_die "Purge aborted — soft-deleted resources kept."
  else
    echo "[!] --yes supplied: purging listed soft-deleted resources."
  fi
  purge_failures=0
  for line in "${PURGE_LINES[@]}"; do
    kind="${line%%|*}"; rest="${line#*|}"
    name="${rest%%|*}"; rest="${rest#*|}"
    loc="${rest%%|*}"; rg="${rest#*|}"
    corbit_info "Purging $kind '$name' (location $loc) ..."
    case "$kind" in
      keyvault)  az keyvault purge --name "$name" --location "$loc" ;;
      cognitive) az cognitiveservices account purge --name "$name" --location "$loc" --resource-group "$rg" ;;
    esac || { corbit_warn "Purge failed for $kind '$name'."; purge_failures=$((purge_failures + 1)); }
  done
  (( purge_failures )) && corbit_warn "$purge_failures purge(s) failed — retry once deletion finishes."
fi

echo ""
if [[ ${#TARGETS[@]} -gt 0 && "$PURGE" -ne 1 ]]; then
  corbit_info "Deletion requests submitted (--no-wait). Verify completion with:"
  echo "  az group list --tag bootcamp=critical-orbit -o table"
  corbit_warn "Reminder: Key Vault and AIServices stay SOFT-DELETED. A rebuild with the"
  corbit_warn "same squadron number (Mode B) fails until you re-run with --purge."
else
  corbit_ok "Teardown finished."
fi
