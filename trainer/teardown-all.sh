#!/usr/bin/env bash
# =============================================================================
# [TRAINER-ONLY] Project Critical Orbit — teardown-all.sh
#
# Deletes ALL squadron resource groups. Lives in trainer/ deliberately — this
# file is never referenced by participant guides.
#
# Safety guarantees:
#   * Only resource groups matching BOTH criteria are touched:
#       - name matches  rg-corbit-sq*   (exact bootcamp convention)
#       - tag bootcamp=critical-orbit   (explicit bootcamp marker)
#   * The full target list is printed BEFORE any deletion.
#   * Interactive mode requires typing "DELETE" to confirm.
#   * --yes is available for trainer automation but is documented and loud.
#
# Usage:
#   ./teardown-all.sh              # list targets, prompt for confirmation
#   ./teardown-all.sh --yes        # non-interactive (trainer automation)
#   ./teardown-all.sh --dry-run    # list targets only, delete nothing
#   ./teardown-all.sh --help
# =============================================================================
set -euo pipefail

ASSUME_YES=0 DRY_RUN=0
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | head -n -1; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || die "'az' not found."
az account show >/dev/null 2>&1 || die "Not signed in. Run 'az login'."

info "Searching for bootcamp resource groups (name + tag match) ..."
# Name pattern AND tag must BOTH match — belt and braces against accidents.
mapfile -t TARGETS < <(
  az group list --tag bootcamp=critical-orbit \
    --query "[?starts_with(name, 'rg-corbit-sq')].name" -o tsv
)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  info "No matching resource groups found. Nothing to do."
  exit 0
fi

echo ""
echo "=================  TARGETS FOR DELETION  ================="
printf '  %s\n' "${TARGETS[@]}"
echo "=========================================================="
echo "  ${#TARGETS[@]} resource group(s) will be PERMANENTLY DELETED."
echo ""

[[ "$DRY_RUN" -eq 1 ]] && { info "Dry-run: exiting without deleting anything."; exit 0; }

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Type DELETE to confirm deletion of all listed groups: " ans
  [[ "$ans" == "DELETE" ]] || die "Aborted — nothing was deleted."
else
  echo "[!] --yes supplied: skipping interactive confirmation."
fi

for rg in "${TARGETS[@]}"; do
  info "Deleting $rg ..."
  az group delete --name "$rg" --yes --no-wait
done

echo ""
info "Deletion requests submitted (--no-wait). Verify completion with:"
echo "  az group list --tag bootcamp=critical-orbit -o table"
