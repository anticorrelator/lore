"""Always-on pure-function tests for the session-injection screen-state matchers.

These do NOT spawn a harness (no LORE_LIVE_PROBES gate) — they feed the recorded
raw rows from observations/<harness>.json to the pure matchers in _driver and
assert the matcher discriminates a composer-ready screen from a permission-modal
screen. That discrimination is exactly what the readiness gate depends on: inject
only when the composer matcher fires and the permission matcher does not.

The recorded rows are the ground-truth screen states captured live during the
exploration pass; pinning the matchers against them means a matcher regression is
caught without paying for a live session. The interaction-row contract itself is
read dynamically from adapters/capabilities.json (never hard-coded per harness).
"""

import pytest

import _driver as d


def _composer_rows(harness, obs):
    if harness == "opencode":
        return obs["composer_signature"]["raw_rows_launch1"]
    return obs["composer_signature"]["raw_rows"]


def _permission_rows(harness, obs):
    if harness == "codex":
        return obs["permission_prompt_signature"]["phase_b_untrusted_mode"]["modal_rows"]
    return obs["permission_prompt_signature"]["raw_rows"]


HARNESSES = ["claude-code", "codex", "opencode"]


@pytest.mark.parametrize("harness", HARNESSES)
def test_composer_matcher_fires_on_composer_state(harness):
    obs = d.load_observation(harness)
    rows = _composer_rows(harness, obs)
    assert d.MATCHERS[harness]["composer"](rows) is True


@pytest.mark.parametrize("harness", HARNESSES)
def test_composer_matcher_rejects_permission_state(harness):
    obs = d.load_observation(harness)
    rows = _permission_rows(harness, obs)
    # A permission modal is NOT composer-ready — the gate must refuse to inject.
    assert d.MATCHERS[harness]["composer"](rows) is False


@pytest.mark.parametrize("harness", HARNESSES)
def test_permission_matcher_fires_on_permission_state(harness):
    obs = d.load_observation(harness)
    rows = _permission_rows(harness, obs)
    assert d.MATCHERS[harness]["permission"](rows) is True


@pytest.mark.parametrize("harness", HARNESSES)
def test_permission_matcher_rejects_composer_state(harness):
    obs = d.load_observation(harness)
    rows = _composer_rows(harness, obs)
    assert d.MATCHERS[harness]["permission"](rows) is False


def test_codex_approved_suggestion_regression_is_ready_not_interactive():
    obs = d.load_observation("codex")
    rows = obs["regression_screens"]["healthy_approved_suggestion"]["raw_rows"]
    assert d.codex_permission_modal(rows) is False
    assert d.codex_composer_ready(rows) is True


def test_codex_recorded_approval_menu_exposes_choice_geometry():
    obs = d.load_observation("codex")
    rows = _permission_rows("codex", obs)
    selected, available = d.codex_modal_options(rows)
    assert selected == 1
    assert available == [1, 2, 3]


# --------------------------------------------------------------------------- #
# Contract-shape checks against adapters/capabilities.json (read dynamically).
# --------------------------------------------------------------------------- #
SIG_ROWS = ["composer_signature", "permission_prompt_signature"]
SEQ_ROWS = ["submit_sequence", "newline_sequence", "graceful_exit_sequence"]
VALUE_ROWS = ["honors_bracketed_paste", "paste_multiline_semantics", "mid_generation_semantics"]


@pytest.mark.parametrize("harness", HARNESSES)
def test_signature_rows_carry_a_nonempty_matcher(harness):
    for name in SIG_ROWS:
        row = d.interaction_row(harness, name)
        assert isinstance(row.get("matcher"), str) and row["matcher"].strip()
        assert row["support"] != "none" and row["evidence"]


@pytest.mark.parametrize("harness", HARNESSES)
def test_sequence_rows_decode_to_nonempty_bytes(harness):
    for name in SEQ_ROWS:
        b = d.sequence_bytes(harness, name)
        assert isinstance(b, bytes) and len(b) >= 1


@pytest.mark.parametrize("harness", HARNESSES)
def test_value_rows_carry_a_value(harness):
    row = d.interaction_row(harness, "honors_bracketed_paste")
    assert isinstance(row["value"], bool)
    assert d.interaction_row(harness, "paste_multiline_semantics")["value"] in (
        "held-multiline-needs-submit",
        "auto-submit-on-close",
    )
    assert d.interaction_row(harness, "mid_generation_semantics")["value"] in (
        "queued-autosubmit",
        "buffered-draft",
        "dropped",
        "interrupts",
    )
