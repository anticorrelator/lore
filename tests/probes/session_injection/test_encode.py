"""Always-on property test for the bracketed-paste encode/refuse helpers.

The injection transport wraps a message body in ESC[200~ .. ESC[201~ so embedded
CR/LF land as literal composer input rather than submits. Two properties matter:

  1. Roundtrip: for any paste-safe body, decode(encode(body)) == body, and the
     wrap has exactly one closing marker (the appended one) — nothing in the body
     can prematurely terminate the paste.
  2. Refusal: a body that itself embeds a bracketed-paste marker is unsafe and
     encode() MUST refuse (raise), never silently sanitize. The critical
     adversarial case is a body containing ESC[201~ — a naive wrap would let it
     close the paste early and smuggle the remainder as live keystrokes.

hypothesis is not a hard dependency of this repo, so the "property-based" part is
a deterministic generative loop (seeded) plus explicit hand-picked cases,
including the ESC[201~ / ESC[200~ adversarial inputs. Runs under plain pytest.
"""

import random

import pytest

import _driver as d

PASTE_END = b"\x1b[201~"
PASTE_START = b"\x1b[200~"

# Byte alphabet biased toward the interesting bytes: ESC, CR, LF, '[', '~', '2',
# '0', '1' — the constituents of the paste markers — so the generator actually
# stumbles onto near-miss and exact-marker sequences rather than only random noise.
_ALPHABET = bytes(range(32, 127)) + b"\x1b\r\n\x00\x03[]~012"


def _gen_bodies(n, seed=20260705):
    rng = random.Random(seed)
    for _ in range(n):
        length = rng.randint(0, 48)
        yield bytes(rng.choice(_ALPHABET) for _ in range(length))


def test_roundtrip_holds_for_generated_safe_bodies():
    checked = 0
    for body in _gen_bodies(4000):
        if not d.paste_is_safe(body):
            # An unsafe body must refuse — never silently roundtrip.
            with pytest.raises(d.UnsafePaste):
                d.paste_encode(body)
            continue
        wrapped = d.paste_encode(body)
        assert wrapped.startswith(PASTE_START)
        assert wrapped.endswith(PASTE_END)
        # Exactly one terminator: the appended one. A safe body contributes none.
        assert wrapped.count(PASTE_END) == 1
        assert d.paste_decode(wrapped) == body
        checked += 1
    # Sanity: the generator produced a meaningful number of safe bodies.
    assert checked > 100


@pytest.mark.parametrize(
    "body",
    [
        b"",
        b"hello world",
        b"line-one\nline-two",
        b"line-one\r\nline-two",
        b"trailing-cr\r",
        b"esc-only\x1b",
        b"open-bracket-esc\x1b[",
        b"near-miss\x1b[200",   # missing the '~' — not a real marker, must be safe
        b"near-miss\x1b[201",
        b"\x00\x03\x1b\r\n",
    ],
)
def test_roundtrip_explicit_safe_cases(body):
    assert d.paste_is_safe(body)
    assert d.paste_decode(d.paste_encode(body)) == body


@pytest.mark.parametrize(
    "body",
    [
        b"before\x1b[201~after",        # THE adversarial case: embedded close bracket
        b"\x1b[201~",                    # bare embedded terminator
        b"payload\x1b[200~nested",       # embedded open bracket (nested paste)
        b"\x1b[200~x\x1b[201~y",         # both markers embedded
        PASTE_END + b"trailing",
    ],
)
def test_encode_refuses_unsafe_bodies(body):
    assert d.paste_is_safe(body) is False
    with pytest.raises(d.UnsafePaste):
        d.paste_encode(body)


def test_embedded_close_bracket_cannot_smuggle_keystrokes():
    # Concretely: were encode to wrap a body containing ESC[201~, the wrapped
    # stream would contain a SECOND terminator inside it — the receiving harness
    # would end the paste at the embedded marker and treat 'after' as live keys.
    body = b"before\x1b[201~after"
    naive = PASTE_START + body + PASTE_END
    assert naive.count(PASTE_END) == 2  # proves the smuggling surface exists
    with pytest.raises(d.UnsafePaste):
        d.paste_encode(body)            # and proves the helper refuses it
