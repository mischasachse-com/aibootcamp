# shellcheck shell=bash
# =============================================================================
# Project Critical Orbit — scripts/lib/common.sh
#
# Shared helpers for the bootcamp shell scripts. This file is SOURCED, never
# executed directly, and is intentionally free of `az` calls so the pure
# functions can be exercised by tests/test_shell_common.py without Azure.
# =============================================================================

# Guard against accidental direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: source this file (e.g. '. scripts/lib/common.sh'), do not run it." >&2
  exit 1
fi

# Exported to sourcing scripts — shellcheck can't see cross-file usage.
# shellcheck disable=SC2034
CORBIT_RG_RE='^rg-corbit-sq[0-9]{2}$'
# shellcheck disable=SC2034
CORBIT_GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
CORBIT_PRINCIPAL_TYPES_RE='^(User|Group|ServicePrincipal)$'
# Deterministic-name suffixes (see day1/infra/main.bicep naming block).
# shellcheck disable=SC2034
CORBIT_SOFTDELETE_NAME_RE='^(kv|ais)-corbit-[0-9]{2}-[a-z0-9]{6}$'

# The six data-plane roles every squadron member needs. Keep in sync with
# roleIds in day1/infra/main.bicep.
# shellcheck disable=SC2034
CORBIT_DATA_PLANE_ROLES=(
  "Cognitive Services OpenAI User"
  "Cognitive Services User"
  "Search Service Contributor"
  "Search Index Data Contributor"
  "Storage Blob Data Contributor"
  "Key Vault Secrets Officer"
)

corbit_die()  { echo "ERROR: $*" >&2; exit 1; }
corbit_info() { echo "[*] $*"; }
corbit_ok()   { echo "[+] $*"; }
corbit_warn() { echo "[!] $*" >&2; }

# Portable usage printer. Prints the comment block between the shebang and the
# `set -...` line. (`head -n -1` is GNU-only; `sed '$d'` works on BSD/macOS too.)
corbit_usage() {
  sed -n '2,/^set -[euo]/p' "$1" \
    | sed '/^# *shellcheck/d; s/^# \{0,1\}//; s/^#$//' | sed '$d'
  exit "${2:-0}"
}

# corbit_team_id <raw> → prints two-digit team id ("7"/"07" → "07").
# `10#` forces base-10 so leading zeros are NOT parsed as octal (08/09 used
# to abort with 'value too great for base'). Returns 1 on invalid input.
corbit_team_id() {
  local raw="${1//[[:space:]]/}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  local n=$((10#$raw))
  (( n >= 1 && n <= 99 )) || return 1
  printf '%02d' "$n"
}

corbit_assert_rg_convention() {
  [[ "$1" =~ $CORBIT_RG_RE ]] \
    || corbit_die "Refusing: '$1' does not match the squadron RG convention rg-corbit-sq<NN>."
}

# corbit_parse_members <csv-file> <team-id>
#   Prints one "identity<TAB>principalType" line per matching row.
#   CSV format: team,identity[,principalType] — type defaults to User and must
#   be User|Group|ServicePrincipal. `#` comment lines and inline `#` comments
#   are stripped; the header row and blank lines are skipped; leading-zero
#   team numbers (08/09) work.
corbit_parse_members() {
  local file="$1" team_id="$2"
  local row_team row_ident row_type
  while IFS=, read -r row_team row_ident row_type _rest; do
    row_team="${row_team%%#*}"; row_ident="${row_ident%%#*}"; row_type="${row_type%%#*}"
    row_team="${row_team//[[:space:]]/}"; row_ident="${row_ident//[[:space:]]/}"; row_type="${row_type//[[:space:]]/}"
    [[ -z "$row_team" || "${row_team:0:1}" == "#" || "$row_team" == "team" ]] && continue
    [[ "$row_team" =~ ^[0-9]+$ ]] || { corbit_warn "members file: skipping non-numeric team '$row_team'"; continue; }
    [[ "$(corbit_team_id "$row_team")" == "$team_id" ]] || continue
    [[ -n "$row_ident" ]] || continue
    row_type="${row_type:-User}"
    [[ "$row_type" =~ $CORBIT_PRINCIPAL_TYPES_RE ]] \
      || corbit_die "members file: invalid principal type '$row_type' for '$row_ident' (User|Group|ServicePrincipal)."
    printf '%s\t%s\n' "$row_ident" "$row_type"
  done < "$file"
}

# corbit_principals_json <assoc-array-name>
#   The array maps objectId -> principalType (User|Group|ServicePrincipal).
#   Prints a JSON array [{"objectId":..., "principalType":...}] for Bicep.
#   Empty array prints [] — the naive "${!arr[@]:-}" idiom crashes with
#   'invalid variable name' once the array has entries.
corbit_principals_json() {
  local -n _principals="$1"
  if (( ${#_principals[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  local oid
  for oid in "${!_principals[@]}"; do
    printf '%s|%s\n' "$oid" "${_principals[$oid]:-User}"
  done | jq -Rn '[inputs | split("|") | {objectId: .[0], principalType: (.[1] // "User")}]'
}

# corbit_detect_python → prints the first working interpreter (python3 may be
# absent or a Microsoft Store stub on Windows Git Bash — verify it runs).
corbit_detect_python() {
  local cand
  for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}
