from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_pending_captures_handler_surface():
    text = (ROOT / "claude-md/10-capture-protocol.md").read_text()
    assert "[capture] N pending candidates" in text
    assert "/remember" in text and "Step 0a" in text


def test_pending_digest_handler_surface():
    text = (ROOT / "claude-md/60-thread-protocol.md").read_text()
    assert "[threads] Pending session digest" in text
    assert "/remember" in text and "Step 0b" in text
