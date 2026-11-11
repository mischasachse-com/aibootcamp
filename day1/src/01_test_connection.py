#!/usr/bin/env python3
"""
Project Critical Orbit — Day 1, Lab 1, Step 01: connection smoke test.

Verifies, in order:
  1. .env configuration is present and complete
  2. DefaultAzureCredential can acquire a token (you ran `az login`)
  3. The AI Services OpenAI endpoint answers a minimal chat completion
  4. The embedding deployment answers a probe
  5. Azure AI Search endpoint is reachable with Entra auth

Chat + embeddings talk to AZURE_OPENAI_ENDPOINT (the account's
<name>.openai.azure.com/openai/v1/ surface) — not the Foundry project
endpoint, whose get_openai_client() route does not serve embeddings
reliably (Azure/azure-sdk-for-python#44532). The project endpoint is only
needed for the Day-3 Foundry Agent stretch backend.

Authentication failures are reported as human-readable remediation steps —
never raw stack traces — because the most common lab failure is an expired
token or a wrong tenant, not a code bug.

Usage:
    python src/01_test_connection.py
    python src/01_test_connection.py --verbose
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from dotenv import load_dotenv

load_dotenv(REPO_ROOT / ".env")

REQUIRED_VARS = [
    "AZURE_RESOURCE_GROUP",
    "AZURE_OPENAI_ENDPOINT",
    "AZURE_SEARCH_ENDPOINT",
    "CHAT_MODEL_DEPLOYMENT",
    "EMBEDDING_MODEL_DEPLOYMENT",
]


def classify_error(exc: BaseException) -> str:
    """Map an exception to a diagnosis bucket (unit-tested — the wrong bucket
    sends participants down the wrong remediation path).

    Buckets: no_login | not_authenticated | not_authorized | not_found |
    unreachable | unexpected
    """
    from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
    from azure.identity import CredentialUnavailableError

    try:
        import openai
    except ImportError:  # pragma: no cover — openai is a required dep
        openai = None  # type: ignore[assignment]

    # No usable credential at all (DefaultAzureCredential exhausted the chain).
    if isinstance(exc, CredentialUnavailableError):
        return "no_login"
    # OpenAI SDK error classes (chat/embedding calls).
    if openai is not None:
        if isinstance(exc, openai.AuthenticationError):
            return "not_authenticated"
        if isinstance(exc, openai.PermissionDeniedError):
            return "not_authorized"
        if isinstance(exc, openai.NotFoundError):
            return "not_found"
        if isinstance(exc, openai.APIConnectionError):
            return "unreachable"
    # Azure SDK: not logged in surfaces as ClientAuthenticationError from
    # DefaultAzureCredential.get_token — NOT "authorized but denied".
    if isinstance(exc, ClientAuthenticationError):
        return "not_authenticated"
    if isinstance(exc, HttpResponseError) and exc.status_code in (401, 403):
        return "not_authenticated" if exc.status_code == 401 else "not_authorized"
    return "unexpected"


def fail(step: str, exc: BaseException) -> NoReturn:
    """Print a human-readable diagnosis for the common failure classes."""
    rg = os.getenv("AZURE_RESOURCE_GROUP", "rg-corbit-sq<NN>")
    print(f"\n[FAIL] {step}")
    print(f"       underlying error: {type(exc).__name__}: {exc}\n")

    diagnosis = classify_error(exc)
    if diagnosis == "no_login":
        print("Diagnosis : no usable Azure credential was found.")
        print("Fix       :")
        print("  1. Run `az login` (add `--tenant <tenant-id>` if you belong to more than one).")
        print("  2. Verify you are in the right subscription:")
        print("       az account show")
    elif diagnosis == "not_authenticated":
        print("Diagnosis : authentication failed — your token was rejected or could")
        print("            not be acquired (expired login or wrong tenant).")
        print("Fix       :")
        print("  1. Run `az login --tenant <tenant-id>` again.")
        print("  2. Confirm the subscription context: az account show")
        print(f"  3. Confirm .env endpoints belong to YOUR squadron (RG {rg}).")
    elif diagnosis == "not_authorized":
        print("Diagnosis : authenticated, but not authorized for this resource —")
        print("            your data-plane role assignment is missing or not propagated.")
        print("Fix       :")
        print("  1. List your assignments on the squadron RG:")
        print(f"       az role assignment list --scope /subscriptions/<sub>/resourceGroups/{rg} \\")
        print("         --assignee $(az ad signed-in-user show --query id -o tsv) -o table")
        print("  2. You should see all six data-plane roles (Cognitive Services OpenAI")
        print("     User, Cognitive Services User, Search Service + Index Data")
        print("     Contributor, Storage Blob Data Contributor, Key Vault Secrets")
        print("     Officer). If any are missing, ask the TRAINER — participants")
        print("     cannot assign roles (trainer runs assign-squadron-access.sh).")
        print("  3. RBAC propagation can take a few minutes — wait and retry.")
    elif diagnosis == "not_found":
        print("Diagnosis : endpoint or model deployment not found (404).")
        print("Fix       :")
        print("  1. Check .env: AZURE_OPENAI_ENDPOINT must be https://<account>.openai.azure.com/")
        print("     and CHAT_MODEL_DEPLOYMENT / EMBEDDING_MODEL_DEPLOYMENT must match")
        print("     the deployment names (defaults: gpt-4.1, text-embedding-3-large).")
        print("  2. Re-run scripts/setup-squadron.sh to regenerate .env.")
    elif diagnosis == "unreachable":
        print("Diagnosis : could not reach the endpoint (DNS/network/proxy).")
        print("Fix       : check connectivity/VPN; verify the endpoint hostname in .env.")
    else:
        print("Diagnosis : unexpected error — see README > Troubleshooting.")
        print("Fix       : re-run with --verbose; if it persists ask the trainer.")
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verbose", action="store_true", help="print raw exception details")
    args = parser.parse_args()

    # --- 1. configuration ----------------------------------------------------
    missing = [v for v in REQUIRED_VARS if not os.getenv(v)]
    if missing:
        print("[FAIL] missing .env variables: " + ", ".join(missing))
        print("       Copy .env.example to .env or run scripts/setup-squadron.sh.")
        sys.exit(1)
    print("[ok] .env configuration complete")

    search_endpoint = os.environ["AZURE_SEARCH_ENDPOINT"].rstrip("/")
    chat_model = os.environ["CHAT_MODEL_DEPLOYMENT"]
    embed_model = os.environ["EMBEDDING_MODEL_DEPLOYMENT"]

    # --- 2. credential --------------------------------------------------------
    try:
        from azure.identity import DefaultAzureCredential

        credential = DefaultAzureCredential()
        token = credential.get_token("https://cognitiveservices.azure.com/.default")
        assert token.token
        print("[ok] DefaultAzureCredential acquired a token (az login active)")
    except Exception as exc:  # noqa: BLE001 — converted to friendly message
        if args.verbose:
            import traceback

            traceback.print_exc()
        fail("credential acquisition", exc)

    # --- 3. OpenAI endpoint: chat ping ---------------------------------------
    try:
        from common.openai_client import get_openai_client

        client = get_openai_client(credential)
        resp = client.chat.completions.create(
            model=chat_model,
            messages=[
                {"role": "system", "content": "You are a terse ground-control assistant."},
                {"role": "user", "content": "Reply with exactly: LINK-EST"},
            ],
            max_completion_tokens=16,
        )
        print(f"[ok] chat model '{chat_model}' replied: {resp.choices[0].message.content.strip()}")
    except Exception as exc:  # noqa: BLE001
        if args.verbose:
            import traceback

            traceback.print_exc()
        fail("chat completion via AI Services endpoint", exc)

    # --- 4. embeddings probe --------------------------------------------------
    try:
        emb = client.embeddings.create(model=embed_model, input="dimension probe")
        dims = len(emb.data[0].embedding)
        expected = int(os.getenv("EXPECTED_EMBEDDING_DIMS", "0") or 0)
        if expected and dims != expected:
            print(f"[FAIL] embedding dims mismatch: model returned {dims}, "
                  f"EXPECTED_EMBEDDING_DIMS={expected}. Fix .env or the deployment.")
            sys.exit(1)
        print(f"[ok] embedding model '{embed_model}' produced a {dims}-dim vector")
    except Exception as exc:  # noqa: BLE001
        fail("embedding probe", exc)

    # --- 5. AI Search reachability -------------------------------------------
    try:
        from azure.search.documents.indexes import SearchIndexClient

        index_name = os.getenv("AZURE_SEARCH_INDEX_NAME", "flight-manuals")
        with SearchIndexClient(endpoint=search_endpoint, credential=credential) as sic:
            names = [ix.name for ix in sic.list_indexes()]
        if index_name in names:
            print(f"[ok] search endpoint reachable; index '{index_name}' already exists")
        else:
            print(f"[ok] search endpoint reachable; index '{index_name}' not created yet")
            print("     (normal at this stage — day1 02_index_flight_manuals.py creates it)")
    except Exception as exc:  # noqa: BLE001
        fail("AI Search connectivity", exc)

    print("\nALL CHECKS PASSED — squadron link is GO.\n")


if __name__ == "__main__":
    main()
