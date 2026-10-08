#!/usr/bin/env bash
# Builds the release zip: dist/TALOD-<version>.zip
#
#   ./build.sh           build (stops if the version, the package contents or the scan fail)
#   ./build.sh --check   build, then run the test suite against the built package
#   ./build.sh --test    run the offline test suite only
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PY=python
command -v "$PY" >/dev/null 2>&1 || PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }

case "${1:-}" in
    --test)
        exec "$PY" tests/run.py
        ;;
    --check)
        "$PY" tools/version.py check
        exec "$PY" tools/build_release.py --check
        ;;
    "")
        "$PY" tools/version.py check
        exec "$PY" tools/build_release.py
        ;;
    *)
        echo "usage: ./build.sh [--check | --test]" >&2
        exit 2
        ;;
esac
