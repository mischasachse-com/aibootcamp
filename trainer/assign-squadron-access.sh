#!/usr/bin/env bash
# =============================================================================
# [TRAINER-ONLY] Project Critical Orbit — assign-squadron-access.sh
#
# Pre-assigns the six data-plane RBAC roles that lab participants need, at the
# squadron resource-group scope. This exists because participants hold only
# `Contributor` on their own rg-corbit-sq<NN> — that does NOT include
# Microsoft.Authorization/roleAssignments/write, so they cannot let the Bicep
# deployment create the role assignments themselves (assignDataPlaneRoles
# stays false on the participant path).
#
# Roles granted (keep in sync with roleIds in day1/infra/main.bicep):
#   Cognitive Services OpenAI User · Cognitive Services User ·
#   Search Service Contributor · Search Index Data Contributor ·
#   Storage Blob Data Contributor · Key Vault Secrets Officer
#
# Usage:
#   ./assign-squadron-access.sh --team 7 --members-file members.csv
#   ./assign-squadron-access.sh --team 7 --member-object-ids <guid>[,<guid:Type>...]
#   ./assign-squadron-access.sh --all-teams --members-file members.csv --yes
#
# Options:
#   --team N / --all-teams   Which squadron(s) to grant access to.
#   --members-file CSV       `team,identity[,type]` rows; `type` defaults to
#                            User (Group/ServicePrincipal need a raw object ID).
#   --member-object-ids      Comma-separated GUIDs, optional :Type suffix.
#   --yes                    Skip the confirmation prompt.
#   --dry-run                Show what would be assigned; change nothing.
#   -h, --help               Show this help.
#
# Must be run by an identity with roleAssignments/write on the squadron RGs
# (e.g. subscription Owner or User Access Administrator). Re-running is safe:
# already-existing assignments are reported, not duplicated.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"

TEAM="" ALL_TEAMS=0 MEMBERS_FILE="" MEMBER_OIDS_RAW="" ASSUME_YES=0 DRY_RUN=0

usage() { corbit_usage "$0" "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)               TEAM="${2:?--team needs a value}"; shift 2 ;;
    --all-teams)          ALL_TEAMS=1; shift ;;
    --members-file)       MEMBERS_FILE="${2:?--members-file needs a value}"; shift 2 ;;
    --member-object-ids)  MEMBER_OIDS_RAW="${MEMBER_OIDS_RAW:+${MEMBER_OIDS_RAW},}${2:?needs value}"; shift 2 ;;
    --yes|-y)             ASSUME_YES=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || corbit_die "'az' not found."
az account show >/dev/null 2>&1 || corbit_die "Not signed in. Run 'az login'."
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
corbit_info "Subscription: $SUBSCRIPTION_ID"

# ---------------------------------------------------------- resolve members --
# ASSIGNMENTS maps "<teamId>|<objectId>" -> principalType.
declare -A ASSIGNMENTS=()

add_principal() {
  local team_id="$1" ident="$2" ptype="${3:-User}"
  if [[ "$ident" =~ $CORBIT_GUID_RE ]]; then
    ASSIGNMENTS["${team_id}|${ident}"]="$ptype"
    return 0
  fi
  if [[ "$ptype" != "User" ]]; then
    corbit_warn "'$ident' (team $team_id): non-GUID identities must be type User — skipping."
    return 0
  fi
  local oid
  if oid="$(az ad user show --id "$ident" --query id -o tsv 2>/dev/null)"; then
    ASSIGNMENTS["${team_id}|${oid}"]=User
    corbit_info "  resolved $ident -> $oid"
  else
    corbit_warn "  could not resolve '$ident' (team $team_id). Pass the object ID instead"
    corbit_warn "  (member runs: az ad signed-in-user show --query id -o tsv)."
  fi
}

# ------------------------------------------------------------ pick squadrons --
declare -a TEAMS=()
if [[ "$ALL_TEAMS" -eq 1 ]]; then
  [[ -f "$MEMBERS_FILE" ]] || corbit_die "--all-teams requires --members-file (teams are read from the CSV)."
  while IFS=, read -r row_team _rest; do
    row_team="${row_team%%#*}"; row_team="${row_team//[[:space:]]/}"
    [[ "$row_team" =~ ^[0-9]+$ ]] || continue
    tid="$(corbit_team_id "$row_team")" || continue
    TEAMS+=("$tid")
  done < "$MEMBERS_FILE"
  mapfile -t TEAMS < <(printf '%s\n' "${TEAMS[@]:-}" | sed '/^$/d' | sort -u)
  (( ${#TEAMS[@]} )) || corbit_die "No team rows found in $MEMBERS_FILE."
elif [[ -n "$TEAM" ]]; then
  TEAMS=()
  tid="$(corbit_team_id "$TEAM")" || corbit_die "Invalid --team '$TEAM'."
  TEAMS=("$tid")
else
  corbit_die "Pass --team N or --all-teams."
fi

for tid in "${TEAMS[@]}"; do
  if [[ -n "$MEMBERS_FILE" ]]; then
    [[ -f "$MEMBERS_FILE" ]] || corbit_die "Members file not found: $MEMBERS_FILE"
    while IFS=$'\t' read -r ident ptype; do
      add_principal "$tid" "$ident" "$ptype"
    done < <(corbit_parse_members "$MEMBERS_FILE" "$tid")
  fi
  if [[ -n "$MEMBER_OIDS_RAW" ]]; then
    IFS=',' read -r -a extra <<< "$MEMBER_OIDS_RAW"
    for entry in "${extra[@]}"; do
      entry="${entry//[[:space:]]/}"
      oid="${entry%%:*}"; ptype="${entry#*:}"
      [[ "$entry" == *:* ]] || ptype="User"
      [[ "$oid" =~ $CORBIT_GUID_RE ]] || corbit_die "--member-object-ids expects GUIDs (optional :Type), got '$entry'."
      [[ "$ptype" =~ $CORBIT_PRINCIPAL_TYPES_RE ]] || corbit_die "Invalid principal type in '$entry'."
      add_principal "$tid" "$oid" "$ptype"
    done
  fi
done

(( ${#ASSIGNMENTS[@]} )) || corbit_die "No principals resolved — check the members file / --member-object-ids."

# ------------------------------------------------------------------- report --
echo ""
echo "=================  ROLE ASSIGNMENT PLAN  ================="
for tid in "${TEAMS[@]}"; do
  count=0
  for key in "${!ASSIGNMENTS[@]}"; do
    [[ "$key" == "$tid|"* ]] && count=$((count + 1))
  done
  echo "  rg-corbit-sq${tid} : $count principal(s) x ${#CORBIT_DATA_PLANE_ROLES[@]} roles"
done
echo "=========================================================="

[[ "$DRY_RUN" -eq 1 ]] && { corbit_info "Dry-run: nothing assigned."; exit 0; }

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Proceed with these role assignments? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || corbit_die "Aborted."
fi

# ------------------------------------------------------------------- assign --
failures=0
for key in "${!ASSIGNMENTS[@]}"; do
  tid="${key%%|*}"; oid="${key#*|}"; ptype="${ASSIGNMENTS[$key]}"
  rg="rg-corbit-sq${tid}"
  scope="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${rg}"
  if ! az group show -n "$rg" >/dev/null 2>&1; then
    corbit_warn "$rg does not exist — create it first (az group create -n $rg -l <region> --tags bootcamp=critical-orbit squadron=$tid), then re-run."
    failures=$((failures + 1))
    continue
  fi
  for role in "${CORBIT_DATA_PLANE_ROLES[@]}"; do
    if az role assignment create \
        --assignee-object-id "$oid" --assignee-principal-type "$ptype" \
        --role "$role" --scope "$scope" --output none 2>/dev/null; then
      corbit_ok "$rg: '$role' -> $oid ($ptype)"
    else
      # Most common benign cause: assignment already exists (idempotent re-run).
      corbit_warn "$rg: could not assign '$role' to $oid — already assigned, or missing rights?"
      failures=$((failures + 1))
    fi
  done
done

echo ""
if (( failures )); then
  corbit_warn "$failures assignment attempt(s) failed — re-check with:"
  echo "  az role assignment list -g rg-corbit-sq<NN> --assignee <oid> -o table"
  exit 1
fi
corbit_ok "All role assignments submitted. Data-plane propagation can take a few minutes."
