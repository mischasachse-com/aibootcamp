"""H1 regression: 01_test_connection.py must map exceptions to the right
diagnosis — 'not logged in' (ClientAuthenticationError) used to be reported
as 'authenticated but not authorized', and OpenAI 401/403s fell through to
'unexpected'."""

import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MOD_PATH = REPO_ROOT / "day1" / "src" / "01_test_connection.py"


@pytest.fixture(scope="module")
def mod():
    spec = importlib.util.spec_from_file_location("test_connection", MOD_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _openai_exc(cls, status):
    import httpx

    req = httpx.Request("POST", "https://example.openai.azure.com/openai/v1/x")
    resp = httpx.Response(status, request=req)
    return cls("boom", response=resp, body=None)


def test_not_logged_in_is_not_authorized_bug(mod):
    from azure.identity import CredentialUnavailableError
    from azure.core.exceptions import ClientAuthenticationError

    assert mod.classify_error(CredentialUnavailableError("no chain")) == "no_login"
    # THE historical bug: DAC raises ClientAuthenticationError when the user
    # simply isn't logged in — must NOT land in 'not_authorized'.
    assert mod.classify_error(ClientAuthenticationError("get_token failed")) == "not_authenticated"


def test_openai_auth_errors(mod):
    openai = pytest.importorskip("openai")
    assert mod.classify_error(_openai_exc(openai.AuthenticationError, 401)) == "not_authenticated"
    assert mod.classify_error(_openai_exc(openai.PermissionDeniedError, 403)) == "not_authorized"
    assert mod.classify_error(_openai_exc(openai.NotFoundError, 404)) == "not_found"


def test_azure_http_errors(mod):
    from azure.core.exceptions import HttpResponseError

    e401 = HttpResponseError("unauth")
    e401.status_code = 401
    e403 = HttpResponseError("denied")
    e403.status_code = 403
    assert mod.classify_error(e401) == "not_authenticated"
    assert mod.classify_error(e403) == "not_authorized"


def test_unexpected_falls_through(mod):
    assert mod.classify_error(ValueError("nope")) == "unexpected"
