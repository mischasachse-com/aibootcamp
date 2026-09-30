"""Regression tests for the pure-bash logic in scripts/lib/common.sh.

The review found several failures that only surface at runtime (octal team
numbers, the "${!arr[@]:-}" crash, CSV comment handling). These tests execute
the real library through bash — no Azure needed — and are skipped on machines
without bash (CI/devcontainer always run them).
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
LIB = REPO_ROOT / "scripts" / "lib" / "common.sh"

bash = shutil.which("bash")
pytestmark = pytest.mark.skipif(bash is None, reason="bash not available")


def run_bash(snippet: str) -> subprocess.CompletedProcess:
    script = f'. "{LIB.as_posix()}"\n{snippet}'
    return subprocess.run(
        [bash, "-c", script], capture_output=True, text=True, timeout=30
    )


# ---------------------------------------------------------------- team ids --

@pytest.mark.parametrize("raw,expected", [
    ("1", "01"), ("7", "07"), ("08", "08"), ("09", "09"), ("42", "42"), ("99", "99"),
])
def test_team_id_leading_zeros_and_normal(raw, expected):
    proc = run_bash(f'corbit_team_id "{raw}"')
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == expected


@pytest.mark.parametrize("raw", ["0", "100", "-3", "x", "1a", "", "007x"])
def test_team_id_rejects_invalid(raw):
    proc = run_bash(f'corbit_team_id "{raw}"')
    assert proc.returncode != 0


def test_setup_script_team_flag_no_longer_octal():
    """C6 regression: --team 08 must survive into TEAM_ID without crashing."""
    proc = subprocess.run(
        [bash, "-c",
         f'TEAM="08"; . "{LIB.as_posix()}"; corbit_team_id "$TEAM"'],
        capture_output=True, text=True, timeout=30,
    )
    assert proc.returncode == 0
    assert "value too great for base" not in proc.stderr
    assert proc.stdout.strip() == "08"


# ------------------------------------------------------------- members CSV --

CSV = """\
# comment line
team,identity
1,alice@example.com
08,bob@example.com
9,carol@example.com
2,9f6c1d2e-aaaa-bbbb-cccc-1234567890ab   # inline comment (H8 regression)
2,11111111-2222-3333-4444-555555555555,Group
bad,someone@example.com
"""


def test_parse_members_filters_and_normalizes(tmp_path):
    csv = tmp_path / "members.csv"
    csv.write_text(CSV, encoding="utf-8")
    proc = run_bash(f'corbit_parse_members "{csv.as_posix()}" "08"')
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "bob@example.com\tUser\n"


def test_parse_members_strips_inline_comments_and_types(tmp_path):
    csv = tmp_path / "members.csv"
    csv.write_text(CSV, encoding="utf-8")
    proc = run_bash(f'corbit_parse_members "{csv.as_posix()}" "02"')
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.strip().splitlines()
    assert "9f6c1d2e-aaaa-bbbb-cccc-1234567890ab\tUser" in lines
    assert "11111111-2222-3333-4444-555555555555\tGroup" in lines
    # the GUID must not carry the comment remnant
    assert not any("#" in line for line in lines)


def test_parse_members_rejects_bad_type(tmp_path):
    csv = tmp_path / "members.csv"
    csv.write_text("3,abc-def,Alien\n", encoding="utf-8")
    proc = run_bash(f'corbit_parse_members "{csv.as_posix()}" "03"')
    assert proc.returncode != 0
    assert "invalid principal type" in proc.stderr


# ------------------------------------------------------- principals JSON ----

def test_principals_json_empty():
    proc = run_bash('declare -A P=(); corbit_principals_json P')
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == []


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq not installed")
def test_principals_json_populated():
    """C1 regression: a non-empty assoc array must not crash."""
    snippet = (
        'declare -A P=(["9f6c1d2e-aaaa-bbbb-cccc-1234567890ab"]=User '
        '["11111111-2222-3333-4444-555555555555"]=Group); '
        'corbit_principals_json P'
    )
    proc = run_bash(snippet)
    assert proc.returncode == 0, proc.stderr
    data = {p["objectId"]: p["principalType"] for p in json.loads(proc.stdout)}
    assert data == {
        "9f6c1d2e-aaaa-bbbb-cccc-1234567890ab": "User",
        "11111111-2222-3333-4444-555555555555": "Group",
    }


def _code_lines(path: Path) -> str:
    """Script text with comment lines stripped (comments may document the bug)."""
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


def test_no_broken_array_default_idiom_in_scripts():
    """The "${!arr[@]:-}" idiom crashes on non-empty assoc arrays — ban it."""
    import re

    bad = re.compile(r"\$\{!\w+\[@\]:-")
    for script in list(REPO_ROOT.glob("scripts/**/*.sh")) + list(REPO_ROOT.glob("trainer/*.sh")):
        assert not bad.search(_code_lines(script)), script.name


# ------------------------------------------------------------ conventions --

def test_rg_convention():
    for good in ("rg-corbit-sq01", "rg-corbit-sq99", "rg-corbit-sq08"):
        assert run_bash(f'[[ "rg" =~ x ]]; corbit_assert_rg_convention {good}').returncode == 0
    for bad in ("rg-corbit-sq1", "rg-corbit-sqABC", "rg-corbit-sq01x", "rg-other-01"):
        assert run_bash(f'corbit_assert_rg_convention {bad}').returncode != 0


def test_softdelete_name_convention():
    for good, bad in (
        ("kv-corbit-07-a1b2c3", "rg-corbit-sq07"),
        ("ais-corbit-99-ff00ee", "kv-corbit-07-ABCDEF"),
    ):
        proc = run_bash(f'[[ "{good}" =~ $CORBIT_SOFTDELETE_NAME_RE ]]')
        assert proc.returncode == 0, good
        proc = run_bash(f'[[ "{bad}" =~ $CORBIT_SOFTDELETE_NAME_RE ]]')
        assert proc.returncode != 0, bad


# ---------------------------------------------------------------- scripts ---
def test_all_shell_scripts_parse():
    """bash -n on every script — catches syntax errors without executing."""
    scripts = sorted(REPO_ROOT.glob("scripts/**/*.sh")) + sorted(
        REPO_ROOT.glob("trainer/*.sh")
    )
    assert scripts, "no shell scripts found"
    for s in scripts:
        proc = subprocess.run(
            [bash, "-n", str(s)], capture_output=True, text=True, timeout=30
        )
        assert proc.returncode == 0, f"{s.name}: {proc.stderr}"


def test_scripts_use_lf_line_endings():
    """H9 regression: CRLF in .sh breaks bash on any platform."""
    for s in list(REPO_ROOT.glob("scripts/**/*.sh")) + list(REPO_ROOT.glob("trainer/*.sh")):
        assert b"\r\n" not in s.read_bytes(), f"{s.name} has CRLF endings"


def test_usage_printer_is_posix():
    """head -n -1 is GNU-only and fails on macOS — scripts must not use it."""
    for s in list(REPO_ROOT.glob("scripts/**/*.sh")) + list(REPO_ROOT.glob("trainer/*.sh")):
        assert "head -n -1" not in _code_lines(s), s.name
