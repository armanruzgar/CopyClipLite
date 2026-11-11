#!/usr/bin/env bash
# Records what the test run leaves behind on the machine.
#
#   check_test_leftovers.sh snapshot <dir>   capture state before the tests
#   check_test_leftovers.sh report <dir>     print what changed after the tests
#
# Set COPYCLIP_ENFORCE_NO_TEST_LEFTOVERS=1 to fail when test preference files remain.
set -euo pipefail

MODE="${1:?usage: check_test_leftovers.sh snapshot|report <dir>}"
STATE_DIR="${2:?usage: check_test_leftovers.sh snapshot|report <dir>}"
PREFERENCES_DIR="$HOME/Library/Preferences"
APP_SUPPORT_DIR="$HOME/Library/Application Support/CopyClipLite"
TEMP_DIR="${TMPDIR:-/tmp}"
PASTEBOARD_SENTINEL="copycliplite-leftover-check-sentinel"

list_preferences() {
  find "$PREFERENCES_DIR" -maxdepth 1 -type f -name '*.plist' -print 2>/dev/null \
    | sed 's|.*/||' | sort
}

list_temp() {
  find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sed 's|.*/||' | sort
}

list_app_support() {
  if [[ -d "$APP_SUPPORT_DIR" ]]; then
    find "$APP_SUPPORT_DIR" -print | sort
  fi
}

test_preference_pattern='CopyClip|Tests[-.][0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$'
installed_app_preferences='^(io\.github\.38st\.CopyClipLite|io\.github\.38st\.CopyClipLite\.preview|com\.local\.CopyClipLite)\.plist$'

case "$MODE" in
  snapshot)
    mkdir -p "$STATE_DIR"
    list_preferences >"$STATE_DIR/preferences.txt"
    list_temp >"$STATE_DIR/temp.txt"
    list_app_support >"$STATE_DIR/app-support.txt"
    # Only on CI: locally this would overwrite the user's clipboard.
    if [[ -n "${CI:-}" ]]; then
      printf '%s' "$PASTEBOARD_SENTINEL" | pbcopy || true
    fi
    echo "Snapshot: $(wc -l <"$STATE_DIR/preferences.txt" | tr -d ' ') preference files," \
      "$(wc -l <"$STATE_DIR/temp.txt" | tr -d ' ') temp entries," \
      "$(wc -l <"$STATE_DIR/app-support.txt" | tr -d ' ') app support entries"
    ;;
  report)
    # Give cfprefsd time to flush pending writes before inspecting the directory.
    sleep 5
    status=0

    list_preferences >"$STATE_DIR/preferences-after.txt"
    comm -13 "$STATE_DIR/preferences.txt" "$STATE_DIR/preferences-after.txt" \
      | { grep -E "$test_preference_pattern" || true; } \
      | { grep -Ev "$installed_app_preferences" || true; } >"$STATE_DIR/preference-leftovers.txt"
    leftover_count="$(wc -l <"$STATE_DIR/preference-leftovers.txt" | tr -d ' ')"
    echo "== Test preference files left in $PREFERENCES_DIR: $leftover_count"
    if [[ "$leftover_count" -gt 0 ]]; then
      echo "-- by prefix:"
      sed -E 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$/<UUID>.plist/' \
        "$STATE_DIR/preference-leftovers.txt" | sort | uniq -c | sort -rn
      echo "-- non-empty files:"
      while IFS= read -r name; do
        contents="$(plutil -convert json -o - "$PREFERENCES_DIR/$name" 2>/dev/null || echo '?')"
        if [[ "$contents" != "{}" ]]; then
          echo "$name: $contents"
        fi
      done <"$STATE_DIR/preference-leftovers.txt"
      echo "-- files:"
      cat "$STATE_DIR/preference-leftovers.txt"
      if [[ "${COPYCLIP_ENFORCE_NO_TEST_LEFTOVERS:-0}" == "1" ]]; then
        echo "::error::The test run left $leftover_count preference files behind."
        status=1
      fi
    fi
    echo "-- all new preference files (any name):"
    comm -13 "$STATE_DIR/preferences.txt" "$STATE_DIR/preferences-after.txt" | sed 's/^/  /'

    list_temp >"$STATE_DIR/temp-after.txt"
    comm -13 "$STATE_DIR/temp.txt" "$STATE_DIR/temp-after.txt" >"$STATE_DIR/temp-new.txt"
    echo "== New entries in $TEMP_DIR: $(wc -l <"$STATE_DIR/temp-new.txt" | tr -d ' ')"
    sed -E 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<UUID>/g' \
      "$STATE_DIR/temp-new.txt" | sort | uniq -c | sort -rn | sed 's/^/  /'

    list_app_support >"$STATE_DIR/app-support-after.txt"
    echo "== Changes under $APP_SUPPORT_DIR:"
    diff "$STATE_DIR/app-support.txt" "$STATE_DIR/app-support-after.txt" | sed 's/^/  /' || true

    echo "== General pasteboard:"
    if [[ -z "${CI:-}" ]]; then
      echo "  not checked outside CI"
    elif [[ "$(pbpaste 2>/dev/null || true)" == "$PASTEBOARD_SENTINEL" ]]; then
      echo "  unchanged (sentinel still present)"
    else
      echo "  changed by the test run"
    fi
    exit "$status"
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 64
    ;;
esac
