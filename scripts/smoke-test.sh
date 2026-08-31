#!/usr/bin/env bash

set -u

PACKAGE="app.lawnchair"
FAILED=false

BASELINE_APK="$(find baseline -maxdepth 1 -type f -name '*.apk' | head -n 1)"
CANDIDATE_APK="candidate/${CANDIDATE_NAME}"

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

echo "Installing known-good APK..."

if ! adb install "$BASELINE_APK"; then
  echo "::error::Failed to install baseline APK."
  exit 1
fi

echo "Launching baseline..."

adb shell monkey \
  -p "$PACKAGE" \
  -c android.intent.category.LAUNCHER \
  1 || true

sleep 10

echo "Installing candidate as update..."

if ! adb install -r "$CANDIDATE_APK"; then
  echo "::error::Failed to update to candidate APK."
  FAILED=true
fi

adb logcat -c || true
adb shell am force-stop "$PACKAGE" || true

echo "Launching candidate..."

adb shell monkey \
  -p "$PACKAGE" \
  -c android.intent.category.LAUNCHER \
  1 || true

sleep 30

echo "Checking process..."

PID="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"

if [ -z "$PID" ]; then
  echo "::error::Lawnchair process is not running."
  FAILED=true
else
  echo "Lawnchair PID: $PID"
fi

echo "Collecting diagnostics..."

adb logcat -d > logcat.txt || true

adb shell dumpsys activity processes \
  > activity-processes.txt || true

adb shell dumpsys activity activities \
  > activity-activities.txt || true

if grep -E -i \
  "ANR in app\.lawnchair|Application Not Responding|Input dispatching timed out|FATAL EXCEPTION|Process: app\.lawnchair|Fatal signal|DeadSystemException|OutOfMemoryError" \
  logcat.txt; then

  echo "::error::Crash or ANR detected."
  FAILED=true
fi

echo "Testing basic interaction..."

adb shell input keyevent KEYCODE_HOME || true

sleep 3

adb shell input swipe \
  500 1200 \
  500 400 \
  300 || true

sleep 5

FINAL_PID="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"

if [ -z "$FINAL_PID" ]; then
  echo "::error::Lawnchair process died during interaction."
  FAILED=true
fi

adb logcat -d > logcat-final.txt || true

if grep -E -i \
  "ANR in app\.lawnchair|Application Not Responding|Input dispatching timed out|FATAL EXCEPTION|Process: app\.lawnchair|Fatal signal|DeadSystemException|OutOfMemoryError" \
  logcat-final.txt; then

  echo "::error::Crash or ANR detected after interaction."
  FAILED=true
fi

if [ "$FAILED" = "true" ]; then
  echo "failed" > smoke-result.txt
  echo "::error::Candidate APK failed smoke test."
else
  echo "passed" > smoke-result.txt
  echo "Candidate APK passed smoke test."
fi

exit 0
