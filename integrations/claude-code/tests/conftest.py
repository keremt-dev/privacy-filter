"""pytest: make the project root importable so 'from server.pipeline import ...' works."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
