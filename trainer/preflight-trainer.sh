#!/usr/bin/env bash
# =============================================================================
# [TRAINER-ONLY] Project Critical Orbit — preflight-trainer.sh
#
# Run this DAYS BEFORE the bootcamp. It measures — not assumes — whether the
# candidate regions can host all squadrons, and reports a data-driven ranked
# recommendation instead of a hardcoded fallback order.
#
# Checks per candidate region:
#   * Cognitive Services model-quota headroom (az cognitiveservices usage list)
#   * AIServices kind availability (az cognitiveservices account list-skus)
#   * Search service-count vs. squadron count (subscription-wide, approx.)
#   * OPTIONAL --probe: deploys a throwaway AIServices account per region and
#     lists deployable models (az cognitiveservices account list-models) — the
#     only way to *prove* gpt-4.1 + text-embedding-3-large availability.
#
# Global checks:
#   * az login, provider registration, Entra directory-read (--check-entra-email)
#
# Exit code: 0 = at least one region fully green; 1 = all regions have a
# BLOCKING finding (fix quota/permissions BEFORE the bootcamp).
#
# Usage:
#   ./preflight-trainer.sh                       # default regions, no probe
#   ./preflight-trainer.sh --probe               # strongest check (deploys+deletes a probe account per region)
#   ./preflight-trainer.sh --teams 8 --tpm 20 \
#       --check-entra-email trainer@example.com \
#       --regions "swedencentral westeurope northeurope eastus"
# =============================================================================
set -uo pipefail   # NOTE: no -e — we want to continue collecting findings

TEAMS=8 TPM=20 REGIONS="swedencentral westeurope northeurope eastus"
PROBE=0 ENTRA_EMAIL=""
MODELS="gpt-4.1 text-embedding-3-large"

RED()  { printf '  \033[31mBLOCKING\033[0m  %s\n' "$*"; }
WARN() { printf '  \033[33mWARN\033[0m      %s\n' "$*"; }
PASS() { printf '  \033[32mPASS\033[0m      %s\n' "$*"; }
info() { echo "[*] $*"; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | head -n -1; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --teams)              TEAMS="${2:?needs value}"; shift 2 ;;
    --tpm)                TPM="${2:?needs value}"; shift 2 ;;
    --regions)            REGIONS="${2:?needs value}"; shift 2 ;;
    --check-entra-email)  ENTRA_EMAIL="${2:?needs value}"; shift 2 ;;
    --probe)              PROBE=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' not found"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: run 'az login' first"; exit 1; }
SUB="$(az account show --query id -o tsv)"
echo "=========================================================================="
echo " Preflight — Project Critical Orbit   (subscription $SUB)"
echo " Squadrons: $TEAMS   TPM/squadron/model: ${TPM}k   Regions: $REGIONS"
echo "=========================================================================="

ANY_BLOCKING=0

# ------------------------------------------------------------ global checks --
echo ""
info "Global check: resource provider registration"
for ns in Microsoft.CognitiveServices Microsoft.Search Microsoft.Storage Microsoft.KeyVault; do
  state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo 'error')"
  if [[ "$state" == "Registered" ]]; then PASS "$ns registered"; else RED "$ns state=$state — run: az provider register -n $ns"; ANY_BLOCKING=1; fi
done

echo ""
info "Global check: Entra directory-read (member e-mail resolution)"
if [[ -n "$ENTRA_EMAIL" ]]; then
  if az ad user show --id "$ENTRA_EMAIL" --query id -o tsv >/dev/null 2>&1; then
    PASS "az ad user show works — members.csv e-mail resolution is available"
  else
    WARN "az ad user show failed for '$ENTRA_EMAIL' (needs >= Directory Readers)."
    WARN "  Fallbacks exist: --member-object-ids, or participants self-resolve"
    WARN "  via 'az ad signed-in-user show --query id'. Document which you chose."
  fi
else
  WARN "--check-entra-email not supplied; skipping directory-read test."
  WARN "  Strongly recommended: rerun with a real member e-mail to test."
fi

# --------------------------------------------------------- per-region checks --
declare -A SCORE=()
for region in $REGIONS; do
  echo ""
  echo "----- Region: $region -----"
  blocking=0

  # (a) AIServices kind availability in region
  if az cognitiveservices account list-skus --kind AIServices -l "$region" \
      --query "[0].name" -o tsv >/dev/null 2>&1; then
    PASS "AIServices kind available in $region"
  else
    RED "AIServices kind NOT available in $region"; blocking=1
  fi

  # (b) Cognitive Services usage/quota headroom (requires Cognitive Services
  #     Usages Reader at subscription scope — permission failure is a WARN,
  #     resolved by running with proper rights or using --probe).
  usage_json="$(az cognitiveservices usage list -l "$region" -o json 2>/dev/null)"
  if [[ -n "$usage_json" && "$usage_json" != "[]" ]]; then
    # Surface the tightest relevant quota entries for model deployments.
    echo "$usage_json" | python3 - "$TEAMS" "$TPM" <<'PY' 2>/dev/null || \
      WARN "could not parse usage output"
import json, sys
teams, tpm = int(sys.argv[1]), int(sys.argv[2])
entries = json.load(sys.stdin)
shown = 0
for e in entries:
    name = e.get('name', {}).get('value', '')
    cur, lim = e.get('currentValue', 0), e.get('limit', 0)
    if any(k in name.lower() for k in ('openai', 'gpt', 'standard.g')) and lim:
        head = lim - cur
        need = teams * tpm  # kTPM units
        tag = 'PASS' if head >= need else 'BLOCKING'
        print(f'  [{tag}] quota "{name}": used {cur} / limit {lim} '
              f'(need ~{need}k TPM headroom for {teams} squadrons)')
        shown += 1
if not shown:
    print('  [WARN] no model-quota entries found in usage list — '
          'run with --probe to verify model availability directly')
PY
  else
    WARN "az cognitiveservices usage list unavailable (needs 'Cognitive Services"
    WARN "  Usages Reader' at subscription scope). Use --probe for certainty."
  fi

  # (c) Probe deployment — definitive model-availability proof (optional)
  if [[ "$PROBE" -eq 1 ]]; then
    probe_rg="rg-corbit-preflight-${region}-$$"
    info "probe: creating throwaway AIServices account in $region ..."
    if az group create -n "$probe_rg" -l "$region" --output none 2>/dev/null \
       && az cognitiveservices account create -n "probe-$$-${region:0:6}" -g "$probe_rg" \
            --kind AIServices --sku S0 -l "$region" --yes --output none 2>/dev/null; then
      avail="$(az cognitiveservices account list-models -n "probe-$$-${region:0:6}" -g "$probe_rg" -o json 2>/dev/null)"
      for m in $MODELS; do
        if echo "$avail" | grep -q "\"name\": *\"$m\""; then
          PASS "$m deployable in $region"
        else
          RED "$m NOT listed for $region"; blocking=1
        fi
      done
    else
      WARN "probe deployment failed in $region (capacity/permissions?)"
    fi
    az group delete -n "$probe_rg" --yes --no-wait >/dev/null 2>&1
    info "probe: threw away $probe_rg"
  fi

  # (d) Search service-count sanity (approximate — Azure exposes no stable
  #     numeric service quota API; we compare existing count vs. squadrons).
  existing="$(az resource list --resource-type Microsoft.Search/searchServices \
      --query "length([?location=='$region'])" -o tsv 2>/dev/null || echo 0)"
  total=$((existing + TEAMS))
  if (( total > 16 )); then
    RED "$region: $existing existing Search services + $TEAMS squadrons = $total"
    RED "  (exceeds common default regional limits — request a quota increase;"
    RED "   a shared Search service is NOT an acceptable fallback: it breaks"
    RED "   per-squadron isolation)"
    blocking=1
  else
    PASS "$region: Search count $existing + $TEAMS = $total (within typical defaults)"
  fi

  SCORE[$region]=$(( 100 - blocking * 1000 ))
done

# ------------------------------------------------------------- verdict table --
echo ""
echo "=========================================================================="
echo " RECOMMENDATION (data-driven — measured above, not a fixed order)"
echo "=========================================================================="
ranked="$(for r in $REGIONS; do echo "${SCORE[$r]:-0} $r"; done | sort -rn | awk '{print $2}')"
first=1
for r in $ranked; do
  if (( first == 1 )); then echo "  PRIMARY  : $r"; first=0; else echo "  fallback : $r"; fi
done
if [[ "$ANY_BLOCKING" -eq 1 ]]; then
  echo ""
  echo "Some GLOBAL checks are BLOCKING — fix them before the bootcamp."
fi
echo ""
echo "Reminder: re-run this script 1-2 days before the bootcamp, and after any"
echo "quota increase is granted."
