#!/usr/bin/env bash
# Actual Manager/Controller/Lifecycle/InjectionStateMachine, fake IPC and field.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_WORK="${MACOSASR_SELFTEST_WORK:-${TMPDIR:-/tmp}}"
mkdir -p "$TASK_WORK"
FIXTURE="$(mktemp -d "$TASK_WORK/session-manager-selftest-XXXXXX")"
trap 'rm -f "$FIXTURE/DaemonEvent.swift" "$FIXTURE/manager-selftest" "$FIXTURE/dummy.sock"; rmdir "$FIXTURE"' EXIT
export MACOSASR_SELFTEST_SOCKET="$FIXTURE/dummy.sock"
cd "$ROOT"

# Compile the production event parser without the real Unix socket transport.
sed '/^final class DaemonClient/,$d' MacApp/macosAsrApp/DaemonClient.swift > "$FIXTURE/DaemonEvent.swift"
swiftc -Onone \
  -target arm64-apple-macosx15.0 \
  -framework Cocoa -framework ApplicationServices \
  "$FIXTURE/DaemonEvent.swift" \
  MacApp/macosAsrApp/TextInjector.swift \
  MacApp/macosAsrApp/InjectionStateMachine.swift \
  MacApp/macosAsrApp/SessionLifecycle.swift \
  MacApp/macosAsrApp/DaemonManager.swift \
  MacApp/macosAsrApp/LiveDictationController.swift \
  MacApp/Tools/RecordingInjector.swift \
  MacApp/Tools/session_manager_test_support.swift \
  MacApp/Tools/session_manager_selftest.swift \
  -o "$FIXTURE/manager-selftest"

SCENARIOS=(acknowledgement quick-restart resumed-session microphone-retry stale-completions stop-while-starting repeated-warmup-failure)
if [[ "$#" -gt 0 ]]; then SCENARIOS=("$@"); fi
for scenario in "${SCENARIOS[@]}"; do
  "$FIXTURE/manager-selftest" "$scenario"
done
