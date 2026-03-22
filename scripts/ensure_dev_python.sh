#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
REQUIREMENTS_FILE="$ROOT_DIR/python_release_requirements.txt"
STAMP_FILE="$VENV_DIR/.requirements.sha256"

if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
  echo "Missing Python requirements file: $REQUIREMENTS_FILE" >&2
  exit 1
fi

BOOTSTRAP_PYTHON=""
if command -v python3 >/dev/null 2>&1; then
  BOOTSTRAP_PYTHON="$(command -v python3)"
elif [[ -x "/usr/bin/python3" ]]; then
  BOOTSTRAP_PYTHON="/usr/bin/python3"
else
  echo "python3 is required to prepare the local development environment." >&2
  exit 1
fi

STAMP_CONTENT="$("$BOOTSTRAP_PYTHON" --version 2>&1)|$(shasum -a 256 "$REQUIREMENTS_FILE" | awk '{print $1}')"
INSTALLED_STAMP=""
if [[ -f "$STAMP_FILE" ]]; then
  INSTALLED_STAMP="$(<"$STAMP_FILE")"
fi

if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
  echo "Creating repo-local Python environment..." >&2
  rm -rf "$VENV_DIR"
  "$BOOTSTRAP_PYTHON" -m venv "$VENV_DIR"
fi

if [[ "$INSTALLED_STAMP" != "$STAMP_CONTENT" ]]; then
  echo "Installing development Python dependencies..." >&2
  "$VENV_DIR/bin/python3" -m pip install \
    --disable-pip-version-check \
    --upgrade \
    -r "$REQUIREMENTS_FILE"
  printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"
fi

