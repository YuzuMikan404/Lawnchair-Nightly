#!/usr/bin/env bash

set -u

PACKAGE="app.lawnchair"
FAILED=false

BASELINE_APK="$(find baseline -maxdepth 1 -type f -name '*.apk' | head -n 1)"
CANDIDATE_APK="candidate/${CANDIDATE_NAME}"

echo "========================================"
echo "Lawnchair upgrade smoke test"
echo "========================================"
echo "Baseline:  $BASELINE_APK"
echo "Candidate: $CANDIDATE_APK"
echo "========================================"

if [ -z "$BASELINE_APK" ] || [ ! -f "$BASELINE_APK" ]; then
  echo "::error::Baseline APK not found."
  exit 1
fi

if [ ! -f "$CANDIDATE_APK" ]; then
  echo "::error::Candidate APK not found."
  exit 1
fi

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

launch_lawnchair() {
  echo "Resolving HOME activity..."

  HOME_ACTIVITY="$(
    adb shell cmd package resolve-activity \
      --brief \
      -a android.intent.action.MAIN \
      -c android.intent.category.HOME \
      "$PACKAGE" 2>/dev/null |
    tr -d '\r' |
    tail -n 1
  )"

  echo "Resolved activity: $HOME_ACTIVITY"

  if [ -z "$HOME_ACTIVITY" ] || [ "$HOME_ACTIVITY" = "No activity found" ]; then
    echo "::error::Unable to resolve Lawnchair HOME activity."
    return 1
  fi

  adb shell am start \
    -W \
    -a android.intent.action.MAIN \
    -c android.intent.category.HOME \
    -n "$HOME_ACTIVITY"
}

process_running() {
  PID="$(
    adb shell pidof "$PACKAGE" 2>/dev/null |
    tr -d '\r' || true
  )"

  [ -n "$PID" ]
}

check_logs() {
  LOG_FILE="$1"

  if grep -E -i \
    "ANR in app\.lawnchair|Application Not Responding|Input dispatching timed out|Process: app\.lawnchair|Fatal signal|DeadSystemException|OutOfMemoryError" \
    "$LOG_FILE"; then

    echo "::error::Crash or ANR signature detected."
    return 1
  fi

  # FATAL EXCEPTION は他の Android プロセスでも起こり得るので、
  # Lawnchair のクラッシュとして確認できる場合だけ失敗させる。
  if grep -A 20 -B 5 \
    "FATAL EXCEPTION" \
    "$LOG_FILE" |
    grep -q "app\.lawnchair"; then

    echo "::error::Lawnchair FATAL EXCEPTION detected."
    return 1
  fi

  return 0
}

# ------------------------------------------------------------
# Install baseline
# ------------------------------------------------------------

echo
echo "Installing known-good APK..."

if ! adb install "$BASELINE_APK"; then
  echo "::error::Failed to install baseline APK."
  exit 1
fi

echo
echo "Installed packages:"
adb shell pm list packages | grep lawnchair || true

# ------------------------------------------------------------
# Launch baseline
# ------------------------------------------------------------

echo
echo "Launching known-good Lawnchair..."

if ! launch_lawnchair; then
  echo "::error::Unable to launch known-good Lawnchair."
  exit 1
fi

sleep 10

if process_running; then
  echo "Baseline Lawnchair PID: $PID"
else
  echo "::error::Known-good Lawnchair did not stay running."
  echo "::error::Baseline itself cannot pass the smoke test."
  exit 1
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

if [ "$FAILED" != "true" ]; then

  adb logcat -c || true

  adb shell am force-stop "$PACKAGE" || true

  sleep 2

  # ----------------------------------------------------------
  # Launch candidate
  # ----------------------------------------------------------

  echo
  echo "Launching updated Lawnchair..."

  if ! launch_lawnchair; then
    echo "::error::Unable to launch updated Lawnchair."
    FAILED=true
  fi

  # Give startup crashes and ANRs time to occur.
  sleep 30

  # ----------------------------------------------------------
  # Process check
  # ----------------------------------------------------------

  echo
  echo "Checking candidate process..."

  if process_running; then
    echo "Candidate Lawnchair PID: $PID"
  else
    echo "::error::Lawnchair process is not running after update."
    FAILED=true
  fi

  # ----------------------------------------------------------
  # Diagnostics
  # ----------------------------------------------------------

  echo
  echo "Collecting diagnostics..."

  adb logcat -d > logcat.txt || true

  adb shell dumpsys activity processes \
    > activity-processes.txt || true

  adb shell dumpsys activity activities \
    > activity-activities.txt || true

  adb shell dumpsys window \
    > window.txt || true

  # ----------------------------------------------------------
  # Crash / ANR detection
  # ----------------------------------------------------------

  echo
  echo "Checking logs..."

  if ! check_logs logcat.txt; then
    FAILED=true
  fi

  # ----------------------------------------------------------
  # Interaction test
  # ----------------------------------------------------------

  echo
  echo "Testing HOME interaction..."

  adb shell input keyevent KEYCODE_HOME || true

  sleep 3

  adb shell input swipe \
    500 1200 \
    500 400 \
    300 || true

  sleep 5

  # ----------------------------------------------------------
  # Final process check
  # ----------------------------------------------------------

  if process_running; then
    echo "Final Lawnchair PID: $PID"
  else
    echo "::error::Lawnchair process died during interaction."
    FAILED=true
  fi

  # ----------------------------------------------------------
  # Final diagnostics
  # ----------------------------------------------------------

  adb logcat -d > logcat-final.txt || true

  if ! check_logs logcat-final.txt; then
    FAILED=true
  fi
fi

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "========================================"

if [ "$FAILED" = "true" ]; then
  echo "failed" > smoke-result.txt
  echo "::error::Candidate APK failed smoke test."
else
  echo "passed" > smoke-result.txt
  echo "Candidate APK passed smoke test."
fi

echo "========================================"

# Return success so diagnostics can be uploaded.
# The workflow rejects the candidate afterwards.
exit 0
