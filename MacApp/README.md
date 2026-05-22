# MacApp

Menu bar app (Swift) — live dictation UI, text injection, and `asr_daemon` lifecycle.

**Build:** Command Line Tools + `swiftc` only (no Xcode project).

```bash
cd /path/to/macosAsr
./scripts/build_macapp.sh
./scripts/launch_macapp.sh
```

Full setup: [README.md](../README.md) (English) · [README.zh-CN.md](../README.zh-CN.md)

## Layout

| Path | Role |
|------|------|
| `macosAsrApp/*.swift` | App source |
| `macosAsrApp/Info.plist` | Bundle metadata + mic usage string |
| `macosAsrApp/macosAsrApp.entitlements` | Sandbox off (dev/self-build) |
| `macosAsrApp/GlobalHotkeyMonitor.swift` | Global **⌥Z** toggle (`CGEventTap`) |
| `Assets/AppIcon.png` | Icon source → `build_icon.sh` → `.icns` |
| `Tools/p0c_selftest.swift` | Headless injection state machine test |

## Menu bar states

| Display | Meaning |
|---------|---------|
| `⏳ ASR` | Loading model / calibrating |
| `🎤 ASR` | Ready |
| `🟢 Dictating…` | Live session active |
| `⚠️ ASR` | Error — see `log/macapp.log` |

## Keyboard shortcut

| Shortcut | Action |
|----------|--------|
| **⌥Z** (Option+Z) | Toggle **Start / Stop Live Dictation** from any app |

- Implemented via session-level **`CGEventTap`** (`GlobalHotkeyMonitor.swift`); matching **⌥Z** is consumed so text fields do not receive **`Ω`**.
- Requires **Input Monitoring** (listen) + **Accessibility** (consume + inject).
- Menu item shows the same shortcut; menu click still works without opening the menu first for the global path.

## Settings

**Settings…** (⌘,) — recognition language (Chinese / English), stored in  
`~/Library/Application Support/macosAsr/config.json`.

Default partial interval: **0.5s** (`asr/config.py`; not in Settings UI).

## Logs

- `log/macapp.log` — this app
- `log/daemon.log` — ASR backend
