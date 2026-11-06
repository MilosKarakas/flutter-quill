#!/usr/bin/env bash
# Builds the harness app, runs the feature checks in Chrome, and optionally
# compares regular editing against a baseline git ref.
#
#   ./run.sh                      feature checks on a profile build
#   ./run.sh --baseline 3695039   feature checks + regression comparison
#   ./run.sh --debug              feature checks on a debug (DDC) build, the
#                                 compiler `flutter run` uses; it type-checks
#                                 JS interop values that profile builds accept
#
# Env: CHROME (browser path), PORT (default 8790), BASE_PORT (default 8791).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8790}"
BASE_PORT="${BASE_PORT:-8791}"
OUT="$HERE/results"
mkdir -p "$OUT"

PIDS=()
TMP=""
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT

build() { # <app dir> <entry point>
  (
    cd "$1"
    flutter pub get --offline >/dev/null 2>&1 || flutter pub get >/dev/null
    flutter build web --profile --no-tree-shake-icons --no-wasm-dry-run -t "$2" >/dev/null
  )
}

serve() { # <app dir> <port>
  (cd "$1/build/web" && exec python3 -m http.server "$2" >/dev/null 2>&1) &
  PIDS+=("$!")
  sleep 1
}

if [ ! -d "$HERE/driver/node_modules" ]; then
  (cd "$HERE/driver" && npm install --silent)
fi

if [ "${1:-}" = "--debug" ]; then
  echo "Serving a debug build of the harness against this checkout..."
  rm -f "$OUT/debug-server.log"
  (cd "$HERE/app" && { flutter pub get --offline >/dev/null 2>&1 || flutter pub get >/dev/null; })
  (cd "$HERE/app" && exec flutter run -d web-server --web-port "$PORT" -t lib/main.dart --no-pub \
    > "$OUT/debug-server.log" 2>&1) &
  SERVER_PID="$!"
  PIDS+=("$SERVER_PID")
  until grep -q "is being served" "$OUT/debug-server.log" 2>/dev/null; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then cat "$OUT/debug-server.log"; exit 1; fi
    sleep 1
  done
else
  echo "Building the harness against this checkout..."
  build "$HERE/app" lib/main.dart
  serve "$HERE/app" "$PORT"
fi

status=0
echo "Feature checks:"
node "$HERE/driver/features.js" "http://localhost:$PORT" || status=1

if [ "${1:-}" = "--baseline" ]; then
  REF="${2:?usage: ./run.sh --baseline <git-ref>}"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/quill"
  git -C "$REPO" archive "$REF" | tar -x -C "$TMP/quill"
  cp -R "$HERE/app" "$TMP/app"
  rm -rf "$TMP/app/build" "$TMP/app/.dart_tool" "$TMP/app/pubspec.lock"
  printf 'dependency_overrides:\n  flutter_quill:\n    path: %s\n' "$TMP/quill" \
    > "$TMP/app/pubspec_overrides.yaml"
  echo "Building the harness against $REF..."
  build "$TMP/app" lib/main_baseline.dart
  serve "$TMP/app" "$BASE_PORT"

  echo "Regression scenarios (default editor):"
  node "$HERE/driver/regression.js" "http://localhost:$BASE_PORT" "$OUT/baseline.json" >/dev/null
  node "$HERE/driver/regression.js" "http://localhost:$PORT" "$OUT/current.json" >/dev/null
  # Read-only paste is blocked now; the baseline let a paste event insert.
  python3 "$HERE/driver/diff.py" "$OUT/baseline.json" "$OUT/current.json" readOnly \
    | tee "$OUT/default-diff.txt" | tail -1
  grep -q '^DIFF' "$OUT/default-diff.txt" && status=1

  echo "Regression scenarios (all new formats enabled):"
  EXTRA='mode=full' node "$HERE/driver/regression.js" "http://localhost:$PORT" "$OUT/full.json" >/dev/null
  # These four change on purpose once images are allowed.
  python3 "$HERE/driver/diff.py" "$OUT/baseline.json" "$OUT/full.json" \
    readOnly,pasteImageFileOnly,setContentsWithEmbeds,dropImageFile \
    | tee "$OUT/full-diff.txt" | tail -1
  grep -q '^DIFF' "$OUT/full-diff.txt" && status=1
fi

exit "$status"
