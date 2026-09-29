#!/usr/bin/env bash
# Validate the marketplace manifest and every plugin under plugins/ with
# `claude plugin validate --strict`. Runs them all, then fails if any failed.
set -uo pipefail
cd "$(dirname "$0")/.."

if ! command -v claude >/dev/null 2>&1; then
  echo "validate-plugins: the claude CLI is not on PATH" >&2
  exit 1
fi

status=0
claude plugin validate --strict . || status=1
for dir in plugins/*/; do
  claude plugin validate --strict "${dir%/}" || status=1
done
exit "$status"
