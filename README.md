# macosAsr

**English** | [简体中文](README.zh-CN.md)

**Local menu-bar dictation for macOS**: stream text to the cursor in any app. Audio stays on your machine (Qwen3-ASR + MLX).

Specs: `docs/SDD/` · Progress: `docs/dev/PROGRESS.md`

---

## Core benefits

- **Local-first inference**: Qwen3-ASR + MLX keep audio on your machine.
- **Text lands at the cursor**: no copy/paste, no app switching, no transcript cleanup.
- **Menu-bar workflow**: lightweight Swift shell + Python daemon, built for self-hosted use.

> In the current build, start/stop dictation via **⌥Z** (Option+Z) from any app, or from the menu bar with **Start Live Dictation / Stop Live Dictation** (also shown as **⌥Z**).

---

## Who is this for?

**For developers and power users** who clone, build, and run on their own Mac — not a “download and go” App Store app.

**Good fit if you:**

- Run **macOS 15+ on Apple Silicon**
- Want **on-device** dictation with audio that never leaves your Mac
- Are fine with `./scripts/setup_env.sh` + `./scripts/build_macapp.sh`

**Not a good fit if you:**

- Need a one-click Mac App Store install
- Use an Intel Mac or macOS 14 or older
- Won’t grant **Accessibility** (required to inject text at the cursor) or **Input Monitoring** (required for the global **⌥Z** shortcut)

Distribution: **open source on GitHub + self-build** ([LICENSE](LICENSE)).

---

## Why not another dictation tool?

- **Not cloud dictation**: your audio stays local, which is better for privacy and offline use.
- **Not a record-then-paste workflow**: text is injected directly into the active app instead of leaving you with a transcript to move around.
- **Not a black-box consumer app**: you can build it, inspect logs, switch language and model settings, and control the behavior yourself.

---

## Third-party licenses

| Component | Role | License / notes |
|-----------|------|-----------------|
| **macosAsr code** | App + daemon | [MIT](LICENSE) |
| **ASR logic** | `asr/` core | Derived from ASR-QWEN; see [NOTICE](NOTICE) |
| **[mlx](https://github.com/ml-explore/mlx)** / **[mlx-audio](https://github.com/ml-explore/mlx-audio)** | Local inference | Apache-2.0 (see upstream repos) |
| **[Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit)** | Default ASR model | Downloaded from Hugging Face on first run; follow model card / Qwen terms |
| **numpy**, **sounddevice** | Audio / numerics | Upstream licenses (BSD / MIT) |
| **PortAudio** (optional system dep) | Mic backend | [portaudio.com](http://www.portaudio.com/) |

Model weights are **not** shipped in this repo. First launch downloads ~**3 GB** over the network. Default model: **`mlx-community/Qwen3-ASR-0.6B-8bit`**.

---

## Requirements

| Item | Requirement |
|------|-------------|
| OS | **macOS 15.0+** (Apple Silicon) |
| Python | **3.11+** (3.12 recommended; 3.14 tested locally) |
| RAM | 16 GB recommended (0.6B model) |
| Tools | Xcode **Command Line Tools** (`xcode-select --install`) — **not** full Xcode.app |
| Build | **`scripts/build_macapp.sh`** (`swiftc`) — no `.xcodeproj` in repo |
| Optional | [Homebrew](https://brew.sh) (for PortAudio) |

---

## First-time setup

### 1. Clone

```bash
git clone https://github.com/<your-org>/macosAsr.git
cd macosAsr
```

### 2. Python environment

```bash
./scripts/setup_env.sh
```

Creates `.venv/` and installs pinned packages from `requirements.txt`:

- `mlx` / `mlx-audio` — local ASR
- `numpy` / `sounddevice` — audio capture

If the mic produces no data, install PortAudio:

```bash
brew install portaudio
```

### 3. Code-sign certificate (once)

Avoids losing Accessibility after rebuilds:

```bash
./scripts/create_codesign_cert.sh
```

Enter your **Mac login password** when prompted to set the keychain ACL (one time).

### 4. Build the menu bar app

```bash
./scripts/build_macapp.sh
```

Expected: `Signed with: macosAsr Local`

> **Command Line Tools only** — you do not need Xcode.app; this repo has no `.xcodeproj`.

### 5. Launch

```bash
./scripts/launch_macapp.sh
```

Menu bar shows **`⏳ ASR`**, then **`🎤 ASR`** after ~30s (model load + 3s noise calibration — stay quiet).

> You do **not** need to run `python -m asr_daemon` manually; the app starts it.

### 6. Accessibility (once)

1. **System Settings → Privacy & Security → Accessibility**
2. Enable **macosAsrApp** (toggle ON / blue)
3. If it still fails: remove the old entry with **「−」**, run `./scripts/launch_macapp.sh` again, re-enable
4. **🎤 ASR → Quit (⌘Q)**, then launch again

### 6b. Input Monitoring (once, for global ⌥Z)

1. **System Settings → Privacy & Security → Input Monitoring**
2. Enable **macosAsrApp** (toggle ON)
3. **🎤 ASR → Quit (⌘Q)**, then launch again

Without this, the menu still works; **⌥Z** only works globally after authorization.

### 7. Live dictation

1. Open **Notes** (or another app you’ve verified), place the cursor
2. Press **⌥Z** to start (or menu bar **🎤 ASR → Start Live Dictation**)
3. Speak (Chinese or English — set language under **Settings…**)
4. Press **⌥Z** again to stop (or **Stop Live Dictation**)

While dictating, the menu bar shows **`🟢 Dictating…`**.

### 8. (Optional) Desktop shortcut

Skip this if you prefer `./scripts/launch_macapp.sh` only.

```bash
./scripts/install_desktop_shortcut.sh
```

Creates **`~/Desktop/macosAsr.app`** (launcher icon). Double-click to start — same as `launch_macapp.sh`.

The clone path is stored in `~/Library/Application Support/macosAsr/repo_root` (not baked into the Desktop app). **If you move the repository**, re-run the install script above.

---

## Why code signing?

macOS **Accessibility** permission is tied to the app’s **code identity**. Without a stable certificate:

| Signing | After each `./scripts/build_macapp.sh` |
|---------|----------------------------------------|
| **Ad-hoc** (`codesign -`) | Signature hash changes → Accessibility often **breaks**; you must re-authorize |
| **`macosAsr Local`** (recommended) | Same identity → toggle usually **stays valid** across rebuilds |

Step 3 (`create_codesign_cert.sh`) creates a **local self-signed** cert for development — not Apple Developer Program, not App Store. You can build without it (falls back to ad-hoc), but expect more permission friction.

---

## Launch options

| Method | Command / action | Notes |
|--------|------------------|-------|
| **CLI (dev)** | `./scripts/launch_macapp.sh` | Sets `MACOSASR_ROOT`, kills old instance, cleans stale socket |
| **Desktop** | `./scripts/install_desktop_shortcut.sh` then double-click **`~/Desktop/macosAsr.app`** | Writes `Application Support/macosAsr/repo_root`; re-run install if you move the clone |
| **Login item** | `./scripts/install_login_item.sh install` | Uses same `launch.sh`; remove: `uninstall` |

**Quit (⌘Q)** shuts down the app **and** `asr_daemon`, freeing model memory. If the daemon is stuck, the app waits briefly and then terminates it.

### Desktop shortcut details

1. Run once from your clone: `./scripts/install_desktop_shortcut.sh`
2. A mic-icon **`macosAsr.app`** appears on the Desktop (wrapper, not a copy of the full build)
3. Path resolution: `~/Library/Application Support/macosAsr/launch.sh` reads `repo_root`
4. After **`git clone` to a new directory** or moving the folder: run the install script again

---

## Daily use

```bash
cd /path/to/macosAsr
./scripts/launch_macapp.sh
```

Wait for **`🎤 ASR`** → focus target app → **⌥Z** to start → speak → **⌥Z** to stop.

After code changes:

```bash
./scripts/build_macapp.sh
./scripts/launch_macapp.sh
```

With the `macosAsr Local` cert, you usually **don’t** need to re-grant Accessibility.

### Advanced: partial refresh interval

Default **0.5s** (`asr/config.py`). Override before launch:

```bash
export MACOSASR_PARTIAL_INTERVAL=0.8
./scripts/launch_macapp.sh
```

Lower = snappier live text, more GPU/injection load. Not exposed in the Settings UI.

Recognition language is in **Settings…** (Chinese / English), stored under `~/Library/Application Support/macosAsr/config.json`.

---

## Dependencies

| Dependency | Purpose | Install |
|------------|---------|---------|
| Python 3.11+ | ASR daemon | System / Homebrew |
| `.venv` + `requirements.txt` | Python packages | `./scripts/setup_env.sh` |
| PortAudio | Microphone | `brew install portaudio` |
| Command Line Tools | Swift build | `xcode-select --install` |
| `macosAsr Local` cert | Stable signing | `./scripts/create_codesign_cert.sh` |
| MLX model | ~3 GB first download | Auto from Hugging Face on first run |

See [`requirements.txt`](requirements.txt) for pinned Python versions.

---

## Logs

| File | Contents |
|------|----------|
| `log/macapp.log` | App: launch, daemon state, dictation, errors |
| `log/daemon.log` | Daemon: model load, VAD calibration, sessions |

Policy: [`docs/dev/LOGGING.md`](docs/dev/LOGGING.md). **Full transcript text is not logged.**

```bash
tail -20 log/macapp.log
tail -20 log/daemon.log
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| No 🎤 ASR in menu bar | System Settings → Control Center → disable “Automatically hide and show the menu bar” |
| Accessibility keeps breaking | Confirm build says `Signed with: macosAsr Local`; remove old entry and re-grant |
| Stuck on ⏳ ASR | Wait ~30s; check `log/daemon.log` for model load errors |
| Live but no text | Check `trusted=true` in macapp.log; bring Notes to front before Start |
| **⌥Z** does nothing (menu works) | Grant **Input Monitoring**; Quit and relaunch; check `hotkey_event_tap_started` in macapp.log |
| **Ω** appears when pressing ⌥Z | Rebuild latest app (tap should consume ⌥Z); confirm Accessibility is ON |
| codesign hangs | Run `./scripts/setup_codesign_acl.sh` |
| Quit greyed out | Rebuild (Quit must target the app action) |
| Daemon still in memory after quit | Rebuild the latest app; Quit now waits briefly and terminates a stuck daemon. If a stale process remains, run `pkill -f asr_daemon` |
| Desktop shortcut fails after moving repo | Re-run `./scripts/install_desktop_shortcut.sh` from the new clone path |

---

## Development

```bash
./scripts/test_p0c.sh      # Swift compile + state machine self-test
./scripts/ci_smoke.sh      # Local CI smoke (Python import)
./scripts/build_macapp.sh
```

Official MacApp build: **swiftc via scripts only** (no Xcode project file).

- MacApp details: [`MacApp/README.md`](MacApp/README.md)
- Workflow: [`docs/dev/LARF.md`](docs/dev/LARF.md)
