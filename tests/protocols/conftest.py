"""pytest configuration — add the protocols directory to sys.path."""
import sys
from pathlib import Path

# Allow `from lib import ...` in all test files under this directory.
sys.path.insert(0, str(Path(__file__).parent))
