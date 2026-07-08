"""
Central configuration loader for the export/embedding pipeline.

Reads secrets from a local `.env` file (never committed to git) and
exposes them as validated constants. No key value is ever printed in
full -- only a masked preview, so it's safe to run these scripts with
output visible in shared terminals, CI logs, etc.
"""
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

# Load .env from this directory regardless of where the script is invoked from.
ENV_PATH = Path(__file__).parent / ".env"
load_dotenv(dotenv_path=ENV_PATH)


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value or value.startswith("your-"):
        sys.exit(
            f"\nMissing or unset environment variable: {name}\n"
            f"1. Copy {ENV_PATH.parent / '.env.example'} to {ENV_PATH}\n"
            f"2. Fill in a real value for {name}\n"
            f"(.env is gitignored -- this is expected to be a local-only file)\n"
        )
    return value


def _mask(value: str) -> str:
    if len(value) <= 8:
        return "*" * len(value)
    return f"{value[:4]}...{value[-4:]}"


RAGFLOW_API_KEY = _require("RAGFLOW_API_KEY")
RAGFLOW_BASE_URL = os.environ.get("RAGFLOW_BASE_URL", "http://localhost:9380")
RAGFLOW_DATASET_NAME = os.environ.get("RAGFLOW_DATASET_NAME", "nyc_health_code")

VOYAGE_API_KEY = _require("VOYAGE_API_KEY")
VOYAGE_MODEL = os.environ.get("VOYAGE_MODEL", "voyage-4-large")


def print_config_summary() -> None:
    """Print a confirmation of what's loaded without ever revealing full keys."""
    print("Configuration loaded:")
    print(f"  RAGFLOW_BASE_URL     = {RAGFLOW_BASE_URL}")
    print(f"  RAGFLOW_DATASET_NAME = {RAGFLOW_DATASET_NAME}")
    print(f"  RAGFLOW_API_KEY      = {_mask(RAGFLOW_API_KEY)}")
    print(f"  VOYAGE_API_KEY       = {_mask(VOYAGE_API_KEY)}")
    print(f"  VOYAGE_MODEL         = {VOYAGE_MODEL}")
    print()
