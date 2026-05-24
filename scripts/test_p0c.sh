#!/usr/bin/env bash
# P0c automated checks before asking user to验收 in Notes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSASR_ROOT="$ROOT"
cd "$ROOT"

SWIFT_SOURCES=(
  MacApp/macosAsrApp/AppConfig.swift
  MacApp/macosAsrApp/ConfigManager.swift
  MacApp/macosAsrApp/SettingsWindowController.swift
  MacApp/macosAsrApp/AppLogger.swift
  MacApp/macosAsrApp/ProjectPaths.swift
  MacApp/macosAsrApp/TextInjector.swift
  MacApp/macosAsrApp/InjectionStateMachine.swift
  MacApp/macosAsrApp/DaemonClient.swift
  MacApp/macosAsrApp/DaemonManager.swift
  MacApp/macosAsrApp/LiveDictationController.swift
  MacApp/macosAsrApp/GlobalHotkeyMonitor.swift
  MacApp/macosAsrApp/AppDelegate.swift
  MacApp/macosAsrApp/main.swift
)

echo "== P0c-1: swiftc compile MacApp sources =="
swiftc -Onone \
  -target arm64-apple-macosx15.0 \
  -framework Cocoa \
  -framework ApplicationServices \
  "${SWIFT_SOURCES[@]}" \
  -o /tmp/macosAsrApp_build_check
echo "PASS compile"

echo "== P0c-2: state machine + log self-test =="
/usr/bin/swift MacApp/Tools/p0c_selftest.swift

echo ""
echo "All automated P0c checks passed."
echo "Build .app: ./scripts/build_macapp.sh"
echo "Manual: open MacApp/build/macosAsrApp.app → Accessibility → Notes → Live Dictation"
