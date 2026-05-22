#!/usr/bin/env bash
# 写入 ~/Library/Application Support/macosAsr/repo_root 并安装通用 launch.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="${HOME}/Library/Application Support/macosAsr"
LAUNCHER="${SUPPORT}/launch.sh"

mkdir -p "$SUPPORT"
printf '%s\n' "$ROOT" > "${SUPPORT}/repo_root"

cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SUPPORT="${HOME}/Library/Application Support/macosAsr"
ROOT_FILE="${SUPPORT}/repo_root"
if [[ ! -f "$ROOT_FILE" ]]; then
  echo "macosAsr: missing ${ROOT_FILE}. Run ./scripts/install_desktop_shortcut.sh from your clone." >&2
  exit 1
fi
ROOT="$(tr -d '\n' < "$ROOT_FILE")"
if [[ ! -d "$ROOT/asr_daemon" ]]; then
  echo "macosAsr: repo not found at ${ROOT}. Re-run ./scripts/install_desktop_shortcut.sh." >&2
  exit 1
fi
exec "$ROOT/scripts/launch_macapp.sh"
EOF
chmod +x "$LAUNCHER"
