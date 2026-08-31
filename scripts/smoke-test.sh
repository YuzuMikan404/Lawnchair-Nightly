#!/usr/bin/env bash

set -u

FAILED=false
PACKAGE=""
HOME_ACTIVITY=""
PID=""

BASELINE_APK="$(find baseline -maxdepth 1 -type f -name '*.apk' | head -n 1)"
CANDIDATE_APK="candidate/${CANDIDATE_NAME:-}"

# ------------------------------------------------------------
# Result helpers
# ------------------------------------------------------------

write_result() {
  local result="$1"
  printf '%s\n' "$result" > smoke-result.txt
}

fatal_test_error() {
  echo "::error::$1"
  write_result failed
  exit 0
}

# Always leave a result file behind, even if the script is interrupted by an
# unexpected shell error. A successful run overwrites this with "passed".
write_result failed

echo "========================================"
echo "Lawnchair upgrade smoke test"
echo "========================================"
echo "Baseline:  $BASELINE_APK"
echo "Candidate: $CANDIDATE_APK"
echo "========================================"

if [ -z "$BASELINE_APK" ] || [ ! -f "$BASELINE_APK" ]; then
  fatal_test_error "Baseline APK not found."
fi

if [ -z "${CANDIDATE_NAME:-}" ] || [ ! -f "$CANDIDATE_APK" ]; then
  fatal_test_error "Candidate APK not found."
fi

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

detect_package() {
  local packages

  packages="$(
    adb shell pm list packages 2>/dev/null |
      tr -d '\r' |
      sed 's/^package://' |
      grep -E '^app\.lawnchair([.]|$)' || true
  )"

  # Nightly builds currently use app.lawnchair.nightly. Keep the stable
  # package as a fallback so this test survives future packaging changes.
  if printf '%s\n' "$packages" | grep -qx 'app.lawnchair.nightly'; then
    PACKAGE='app.lawnchair.nightly'
  elif printf '%s\n' "$packages" | grep -qx 'app.lawnchair'; then
    PACKAGE='app.lawnchair'
  else
    PACKAGE="$(printf '%s\n' "$packages" | head -n 1)"
  fi

  if [ -z "$PACKAGE" ]; then
    echo "::error::Unable to detect installed Lawnchair package."
    echo "Installed Lawnchair-like packages:"
    adb shell pm list packages | grep -i lawnchair || true
    return 1
  fi

  echo "Detected package: $PACKAGE"
  return 0
}

resolve_home_activity() {
  local output candidate escaped_package

  HOME_ACTIVITY=""
  escaped_package="${PACKAGE//./\\.}"

  # PackageManager intent parsing expects -p for the package restriction.
  output="$(
    adb shell cmd package resolve-activity \
      --brief \
      -a android.intent.action.MAIN \
      -c android.intent.category.HOME \
      -p "$PACKAGE" 2>/dev/null |
      tr -d '\r' || true
  )"

  candidate="$(
    printf '%s\n' "$output" |
      grep -E "^${escaped_package}/[^[:space:]]+$" |
      tail -n 1 || true
  )"

  if [ -n "$candidate" ]; then
    HOME_ACTIVITY="$candidate"
    return 0
  fi

  echo "::warning::resolve-activity did not return Lawnchair; querying HOME activities."

  output="$(
    adb shell cmd package query-activities \
      --brief \
      -a android.intent.action.MAIN \
      -c android.intent.category.HOME \
      -p "$PACKAGE" 2>/dev/null |
      tr -d '\r' || true
  )"

  candidate="$(
    printf '%s\n' "$output" |
      grep -E "^${escaped_package}/[^[:space:]]+$" |
      head -n 1 || true
  )"

  if [ -n "$candidate" ]; then
    HOME_ACTIVITY="$candidate"
    return 0
  fi

  echo "::warning::Unable to find HOME component using PackageManager."
  echo "Package HOME diagnostics:"
  adb shell dumpsys package "$PACKAGE" |
    grep -A 20 -B 5 -E 'android.intent.action.MAIN|android.intent.category.HOME' || true

  return 1
}

launch_lawnchair() {
  echo "Resolving HOME activity for $PACKAGE..."

  if ! resolve_home_activity; then
    echo "::error::Unable to resolve Lawnchair HOME activity for $PACKAGE."
    return 1
  fi

  echo "Resolved activity: $HOME_ACTIVITY"

  adb shell am start \
    -W \
    -a android.intent.action.MAIN \
    -c android.intent.category.HOME \
    -n "$HOME_ACTIVITY"
}

process_running() {
  PID="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$PID" ]
}

check_logs() {
  local log_file="$1"
  local escaped_package crash_context

  escaped_package="${PACKAGE//./\\.}"

  if grep -E -i -q \
    "ANR in ${escaped_package}([:[:space:]]|$)|Process: ${escaped_package}([,:[:space:]]|$).*OutOfMemoryError|DeadSystemException.*${escaped_package}" \
    "$log_file"; then
    echo "::error::Lawnchair crash or ANR signature detected."
    grep -E -i \
      "ANR in ${escaped_package}([:[:space:]]|$)|Process: ${escaped_package}([,:[:space:]]|$).*OutOfMemoryError|DeadSystemException.*${escaped_package}" \
      "$log_file" || true
    return 1
  fi

  # FATAL EXCEPTION may belong to another process. Only fail when the nearby
  # crash context identifies this Lawnchair package.
  crash_context="$(grep -A 25 -B 5 'FATAL EXCEPTION' "$log_file" || true)"
  if [ -n "$crash_context" ] && printf '%s\n' "$crash_context" | grep -E -q "Process: ${escaped_package}([,:[:space:]]|$)"; then
    echo "::error::Lawnchair FATAL EXCEPTION detected."
    printf '%s\n' "$crash_context" | tail -n 80
    return 1
  fi

  return 0
}

collect_diagnostics() {
  adb logcat -d > logcat.txt || true
  adb shell dumpsys activity processes > activity-processes.txt || true
  adb shell dumpsys activity activities > activity-activities.txt || true
  adb shell dumpsys window > window.txt || true

  if [ -n "$PACKAGE" ]; then
    adb shell dumpsys package "$PACKAGE" > package.txt || true
  fi
}

# ------------------------------------------------------------
# Install baseline
# ------------------------------------------------------------

echo
echo "Installing known-good APK..."

if ! adb install "$BASELINE_APK"; then
  collect_diagnostics
  fatal_test_error "Failed to install baseline APK."
fi

echo
echo "Installed packages:"
adb shell pm list packages | grep -i lawnchair || true

if ! detect_package; then
  collect_diagnostics
  fatal_test_error "Installed baseline package could not be identified."
fi

# ------------------------------------------------------------
# Launch baseline
# ------------------------------------------------------------

echo
echo "Launching known-good Lawnchair..."

if ! launch_lawnchair; then
  collect_diagnostics
  fatal_test_error "Unable to launch known-good Lawnchair."
fi

sleep 10

if process_running; then
  echo "Baseline Lawnchair PID: $PID"
else
  collect_diagnostics
  fatal_test_error "Known-good Lawnchair did not stay running; baseline itself cannot pass the smoke test."
fi

# ------------------------------------------------------------
# Upgrade
# ------------------------------------------------------------

echo
echo "========================================"
echo "Installing candidate as update..."
echo "========================================"

if ! adb install -r "$CANDIDATE_APK"; then
  echo "::error::Failed to update to candidate APK."
  FAILED=true
fi

if [ "$FAILED" != "true" ] && ! adb shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "::error::Lawnchair package disappeared after candidate update: $PACKAGE"
  FAILED=true
fi

if [ "$FAILED" != "true" ]; then
  adb logcat -c || true
  adb shell am force-stop "$PACKAGE" || true
  sleep 2

  echo
  echo "Launching updated Lawnchair..."

  if ! launch_lawnchair; then
    echo "::error::Unable to launch updated Lawnchair."
    FAILED=true
  fi

  # Give startup crashes and ANRs time to occur.
  sleep 30

  echo
  echo "Checking candidate process..."

  if process_running; then
    echo "Candidate Lawnchair PID: $PID"
  else
    echo "::error::Lawnchair process is not running after update."
    FAILED=true
  fi

  echo
  echo "Collecting diagnostics..."
  collect_diagnostics

  echo
  echo "Checking logs..."

  if ! check_logs logcat.txt; then
    FAILED=true
  fi

  echo
  echo "Testing HOME interaction..."

  adb shell input keyevent KEYCODE_HOME || true
  sleep 3
  adb shell input swipe 500 1200 500 400 300 || true
  sleep 5

  if process_running; then
    echo "Final Lawnchair PID: $PID"
  else
    echo "::error::Lawnchair process died during interaction."
    FAILED=true
  fi

  adb logcat -d > logcat-final.txt || true

  if ! check_logs logcat-final.txt; then
    FAILED=true
  fi
else
  collect_diagnostics
fi

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "========================================"

if [ "$FAILED" = "true" ]; then
  write_result failed
  echo "::error::Candidate APK failed smoke test."
else
  write_result passed
  echo "Candidate APK passed smoke test."
fi

echo "========================================"

# Keep this step successful so diagnostics can always be uploaded. The
# workflow rejects a failed candidate after reading smoke-result.txt.
exit 0
