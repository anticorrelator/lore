import re
import sys
from pathlib import Path


def main():
    try:
        text = Path(sys.argv[1]).read_text(encoding="utf-8")
    except (IndexError, OSError, UnicodeError) as exc:
        print(f"Report unavailable: {exc}", file=sys.stderr)
        return 1

    labels = {
        "Task": r"^\s*(?:Task:|\*\*Task:\*\*)",
        **{name: rf"^\s*\*\*{name}:\*\*"
           for name in ("Changes", "Observations", "Tier 2 evidence")},
    }
    missing = [name for name, pattern in labels.items()
               if not re.search(pattern, text, re.MULTILINE)]
    if missing:
        print("Missing report labels: " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
