#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Interop parity check: for every corpus file, assert that BOTH the canonical
# `docker compose config` normalizer AND ComposeKit (via compose-validate)
# accept it. A disagreement means our parser drifted from what docker accepts.
#
#   Scripts/parity.sh [path-to-compose-validate] [corpus-dir]
#
# Note: this proves PARSE fidelity, not runtime behavior — Apple's `container`
# cannot run in CI, so we never boot containers here.
#===----------------------------------------------------------------------===#
set -uo pipefail

VALIDATE="${1:-.build/release/compose-validate}"
CORPUS_DIR="${2:-Tests/ComposeKitTests/Fixtures/corpus}"

if ! command -v docker >/dev/null; then echo "docker not found"; exit 127; fi
if [ ! -x "$VALIDATE" ]; then echo "compose-validate not found at $VALIDATE"; exit 127; fi

fail=0
shopt -s nullglob
for f in "$CORPUS_DIR"/*.yaml "$CORPUS_DIR"/*.yml; do
  dk=0; docker compose -f "$f" config -q >/dev/null 2>&1 || dk=$?
  ck=0; "$VALIDATE" "$f" >/dev/null 2>&1 || ck=$?
  if [ "$dk" -eq 0 ] && [ "$ck" -eq 0 ]; then
    echo "ok    $f (docker + ComposeKit agree)"
  else
    echo "FAIL  $f (docker exit=$dk, ComposeKit exit=$ck)"
    echo "--- docker compose config ---";  docker compose -f "$f" config -q || true
    echo "--- compose-validate ---";       "$VALIDATE" "$f" || true
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "parity: all files accepted by both" || echo "parity: mismatch detected"
exit $fail
