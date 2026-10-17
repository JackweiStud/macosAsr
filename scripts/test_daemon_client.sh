#!/usr/bin/env bash
# Isolated real Unix-socket client checks. No daemon, model, microphone, or CGEvents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$(mktemp -d /tmp/asr-client-build.XXXXXX)"
trap 'rm -rf "$TASK_BUILD"' EXIT
swiftc -Onone \
  -target arm64-apple-macosx15.0 \
  "$ROOT/MacApp/macosAsrApp/DaemonClient.swift" \
  "$ROOT/MacApp/Tools/daemon_client_selftest.swift" \
  -o "$TASK_BUILD/daemon_client_selftest"
"$TASK_BUILD/daemon_client_selftest"
