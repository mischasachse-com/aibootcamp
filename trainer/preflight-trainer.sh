#!/usr/bin/env bash
# =============================================================================
# [TRAINER-ONLY] Project Critical Orbit — preflight-trainer.sh
#
# Run this DAYS BEFORE the bootcamp. It measures — not assumes — whether the
# candidate regions can host all squadrons, and reports a data-driven ranked
# recommendation instead of a hardcoded fallback order.
#
# Checks per candidate region:
#   * AIServices kind availability (az cognitiveservices account list-skus —
#     an empty result counts as BLOCKING, not PASS)
#   * Cognitive Services model-quota headroom PER MODEL × team count
#     (az cognitiveservices usage list). Units caveat: the usage API reports
#     quota in the same units as SKU capacity — for GlobalStandard model
#     deployments that is thousands of tokens/minute (kTPM). VERIFY the
#     printed limit/currentValue magnitudes once against your subscription;
#     if they look like raw tokens rather than kTPM, adjust --tpm accordingly.
#   * Search service-count vs. squadron count (subscription-wide, approx.)
#   * OPTIONAL --probe: deploys a throwaway AIServices account per region and
#     lists deployable models (az cognitiveservices account list-models) — the
#     only way to *prove* gpt-4.1 + text-embedding-3-large availability.
#
# Global checks:
#   * az login, provider registration, a working Python interpreter
#   * Entra directory-read (--check-entra-email): BLOCKING when lookup fails
#     for permission reasons; a plain "user not found" is a WARN only
#     (it still proves directory-read works).
#
# Exit code: 0 = at least one region has no BLOCKING finding AND no global
# check blocked; 1 = every region blocked or a global check blocked — fix
# quota/permissions BEFORE the bootcamp.
#
# Usage:
#   ./preflight-trainer.sh                       # default regions, no probe
#   ./preflight-trainer.sh --probe               # strongest check (deploys+deletes a probe account per region)
#   ./preflight-trainer.sh --teams 8 --tpm 20 \
#       --check-entra-email trainer@example.com \
#       --regions "swedencentral westeurope northeurope eastus"
# =============================================================================
set -uo pipefail   # NOTE: no -e — we want to continue collecting findings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"

TEAMS=8 TPM=20 REGIONS="swedencentral westeurope northeurope eastus"
PROBE=0 ENTRA_EMAIL=""
MODELS="gpt-4.1 text-embedding-3-large"

RED()  { printf '  \033[31mBLOCKING\033[0m  %s\n' "$*"; }
WARN() { printf '  \033[33mWARN\033[0m      %s\n' "$*"; }
PASS() { printf '  \033[32mPASS\033[0m      %s\n' "$*"; }
info() { echo "[*] $*"; }

usage() { corbit_usage "$0" "${1:-0}"; }

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

PYBIN="$(corbit_detect_python)" || true
echo ""
info "Global check: Python interpreter (needed for quota parsing)"
if [[ -n "$PYBIN" ]]; then
  PASS "using '$PYBIN'"
else
  WARN "no working python3/python found — quota checks will be skipped."
  WARN "  On Windows Git Bash the Store stub 'python3' often exists but fails;"
  WARN "  install Python or run inside the devcontainer."
fi

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
  entra_err="$(az ad user show --id "$ENTRA_EMAIL" --query id -o tsv 2>&1 >/dev/null)"
  if [[ -z "$entra_err" ]]; then
    PASS "az ad user show works — members.csv e-mail resolution is available"
  elif grep -qiE 'not.?found|ResourceNotFound|does not exist' <<<"$entra_err"; then
    WARN "'$ENTRA_EMAIL' not found in this tenant — check the address. Directory"
    WARN "  read itself works (the lookup succeeded), so e-mail resolution is fine."
  else
    RED "az ad user show failed for '$ENTRA_EMAIL' — likely insufficient"
    RED "  directory rights (needs >= Directory Readers): $entra_err"
    RED "  members.csv e-mail resolution will fail for every squadron; either"
    RED "  request the rights or collect object IDs (az ad signed-in-user show)."
    ANY_BLOCKING=1
  fi
else
  WARN "--check-entra-email not supplied; skipping directory-read test."
  WARN "  Strongly recommended: rerun with a real member e-mail to test."
fi

# --------------------------------------------------------- per-region checks --
declare -A SCORE=()      # region -> numeric headroom (kTPM); <0 = BLOCKED/unknown
declare -A REGION_NOTE=()
for region in $REGIONS; do
  echo ""
  echo "----- Region: $region -----"
  blocking=0
  min_headroom=-1        # -1 = unknown

  # (a) AIServices kind availability in region — an EMPTY result is blocking;
  #     a successful-but-empty list-skus used to be reported as PASS.
  skus="$(az cognitiveservices account list-skus --kind AIServices -l "$region" \
      --query "[].name" -o tsv 2>/dev/null)"
  if [[ -n "${skus//[[:space:]]/}" ]]; then
    PASS "AIServices kind available in $region (skus: $(echo $skus | tr '\n' ' '))"
  else
    RED "AIServices kind NOT available in $region (list-skus returned nothing)"; blocking=1
  fi

  # (b) Cognitive Services usage/quota headroom per model × team count.
  #     Requires 'Cognitive Services Usages Reader' at subscription scope —
  #     permission failure is a WARN, resolved by running with proper rights
  #     or using --probe.
  usage_json="$(az cognitiveservices usage list -l "$region" -o json 2>/dev/null)"
  if [[ -z "$PYBIN" ]]; then
    WARN "quota check skipped — no Python interpreter."
  elif [[ -n "$usage_json" && "$usage_json" != "[]" ]]; then
    quota_out="$(USAGE_JSON="$usage_json" "$PYBIN" - "$TEAMS" "$TPM" $MODELS <<'PY'
import json, os, sys
teams, tpm = int(sys.argv[1]), int(sys.argv[2])
models = sys.argv[3:]
entries = json.loads(os.environ["USAGE_JSON"])
need = teams * tpm          # kTPM — see units caveat in the header
min_headroom = None
blocking = 0
for model in models:
    # Usage names look like "OpenAI.GlobalStandard.gpt-4.1" — suffix match.
    hits = [e for e in entries
            if e.get('name', {}).get('value', '').lower().endswith(model.lower())]
    if not hits:
        print(f'  [WARN] no usage-quota entry ending in "{model}" — '
              'unknown; --probe is the reliable check', flush=True)
        continue
    for e in hits:
        name = e['name']['value']
        cur, lim = e.get('currentValue') or 0, e.get('limit') or 0
        head = lim - cur
        min_headroom = head if min_headroom is None else min(min_headroom, head)
        if not lim:
            print(f'  [WARN] quota "{name}": limit is 0/missing — verify '
                  'units manually (assumption: values are in kTPM)', flush=True)
        elif head >= need:
            print(f'  [PASS] quota "{name}": used {cur} / limit {lim} '
                  f'(headroom {head}k TPM, need ~{need}k)', flush=True)
        else:
            print(f'  [BLOCKING] quota "{name}": used {cur} / limit {lim} '
                  f'(headroom {head}k TPM < need ~{need}k for {teams} squadrons)',
                  flush=True)
            blocking += 1
print(f'__RESULT__ {blocking} {min_headroom if min_headroom is not None else -1}')
PY
)"
    quota_rc=$?
    # All lines except the __RESULT__ trailer are human-readable output.
    grep -v '^__RESULT__' <<<"$quota_out" || true
    if (( quota_rc != 0 )); then
      WARN "could not parse usage output — quota state unknown (use --probe)"
    else
      result_line="$(grep '^__RESULT__' <<<"$quota_out")"
      quota_blocks="${result_line#__RESULT__ }"; quota_blocks="${quota_blocks%% *}"
      h="${result_line##* }"
      (( quota_blocks > 0 )) && { blocking=1; }
      (( h >= 0 )) && min_headroom="$h"
    fi
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

  # Headroom-based score: regions sort by their tightest measured quota.
  if (( blocking )); then
    SCORE[$region]=-999999; REGION_NOTE[$region]="BLOCKED"
  elif (( min_headroom < 0 )); then
    SCORE[$region]=-1; REGION_NOTE[$region]="quota unknown"
  else
    SCORE[$region]=$min_headroom; REGION_NOTE[$region]="min headroom ${min_headroom}k TPM"
  fi
done

# ------------------------------------------------------------- verdict table --
echo ""
echo "=========================================================================="
echo " RECOMMENDATION (data-driven — sorted by tightest measured quota headroom)"
echo "=========================================================================="
ranked="$(for r in $REGIONS; do echo "${SCORE[$r]:-0} $r"; done | sort -rn | awk '{print $2}')"
first=1
green=0
for r in $ranked; do
  tag="fallback"; (( first == 1 )) && tag="PRIMARY"; first=0
  printf '  %-8s : %-15s %s\n' "$tag" "$r" "${REGION_NOTE[$r]}"
  [[ "${REGION_NOTE[$r]}" != "BLOCKED" ]] && green=$((green + 1))
done
echo ""
if [[ "$ANY_BLOCKING" -eq 1 ]]; then
  echo "Some GLOBAL checks are BLOCKING — fix them before the bootcamp."
fi
if (( green == 0 )); then
  echo "No candidate region is fully green — resolve BLOCKING items and re-run."
fi
echo ""
echo "Reminder: re-run this script 1-2 days before the bootcamp, and after any"
echo "quota increase is granted."

if [[ "$ANY_BLOCKING" -eq 1 || "$green" -eq 0 ]]; then
  exit 1
fi
exit 0
