"""Shared OpenAI client factory for Project Critical Orbit.

Chat completions and embeddings go through the AI Services account's
``<account>.openai.azure.com/openai/v1/`` endpoint — NOT through
``AIProjectClient.get_openai_client()``. That method points at the Foundry
project's ``/openai/v1`` route, which serves the Responses/Conversations
surface; ``embeddings.create`` on that route returns 404
(Azure/azure-sdk-for-python#44532). The project endpoint stays in use only
for the Foundry Agent Service backend (Day 3 stretch).

Required env var:
    AZURE_OPENAI_ENDPOINT — e.g. https://ais-corbit-07-ab12cd.openai.azure.com/
    (written to .env by scripts/setup-squadron.sh from the openAiEndpoint
    Bicep output).
"""

from __future__ import annotations

import os

TOKEN_SCOPE = "https://cognitiveservices.azure.com/.default"


def get_openai_client(credential=None):
    """Return an openai.OpenAI client bound to the squadron AI Services account.

    Entra-only: the bearer-token provider is passed as ``api_key`` so the SDK
    refreshes tokens automatically. No API keys anywhere.
    """
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider
    from openai import OpenAI

    endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT", "").rstrip("/")
    if not endpoint:
        raise RuntimeError(
            "AZURE_OPENAI_ENDPOINT is not set — run scripts/setup-squadron.sh "
            "or add it to .env (e.g. https://<account>.openai.azure.com/)."
        )
    credential = credential or DefaultAzureCredential()
    return OpenAI(
        base_url=f"{endpoint}/openai/v1/",
        api_key=get_bearer_token_provider(credential, TOKEN_SCOPE),
    )
