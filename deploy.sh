#!/bin/bash
set -e

DEPLOY_LENA=false
for arg in "$@"; do
    case "$arg" in
        --lena) DEPLOY_LENA=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
MOD_ID=$(grep '^id=' "$ROOT/mod.info" | cut -d= -f2)

WS_BASE="$HOME/Zomboid/Workshop"
LOCAL_BASE="$HOME/Zomboid/mods"

REMOTE_HOST="lena"
REMOTE_WS_BASE="/home/tony/Zomboid/Workshop"
REMOTE_LOCAL_BASE="/home/tony/Zomboid/mods"

ssh_available() {
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" true 2>/dev/null
}

# Build the mod's "42/" content (media + mod.info + poster) into $1/42.
# We keeps a flat source layout, so assemble the versioned tree here.
sync_42_local() {
    local dst_42="$1"
    rm -rf "$dst_42"
    mkdir -p "$dst_42"
    cp -r "$ROOT/media" "$dst_42/media"
    cp "$ROOT/mod.info" "$dst_42/mod.info"
    [ -f "$ROOT/poster.png" ] && cp "$ROOT/poster.png" "$dst_42/poster.png"
}

sync_42_remote() {
    local dst_42="$1"
    ssh "$REMOTE_HOST" "rm -rf '$dst_42' && mkdir -p '$dst_42'"
    rsync -a --delete "$ROOT/media/" "$REMOTE_HOST:$dst_42/media/"
    rsync -a "$ROOT/mod.info" "$REMOTE_HOST:$dst_42/mod.info"
    [ -f "$ROOT/poster.png" ] && rsync -a "$ROOT/poster.png" "$REMOTE_HOST:$dst_42/poster.png"
}

echo "=== Deploy [$MOD_ID] ==="

# ── Место 1: локальная машина ────────────────────────────────────────────────
ws_root="$WS_BASE/$MOD_ID"
ws_42="$ws_root/Contents/mods/$MOD_ID/42"
local_42="$LOCAL_BASE/$MOD_ID/42"

mkdir -p "$ws_root"
cp "$ROOT/workshop.txt" "$ws_root/workshop.txt"
[ -f "$ROOT/preview.png" ] && cp "$ROOT/preview.png" "$ws_root/preview.png"

sync_42_local "$ws_42"
sync_42_local "$local_42"
echo "  [$MOD_ID] local → $ws_42"
echo "  [$MOD_ID] local → $local_42"

# Локальный Steam content (для локального сервера)
local_steam_42=$(grep -rl "^id=$MOD_ID\$" "$HOME/.local/share/Steam/steamapps/workshop/content/108600/" 2>/dev/null \
    | grep '/mod\.info$' | head -1 | xargs dirname 2>/dev/null || true)
if [ -n "$local_steam_42" ]; then
    rsync -a --delete "$ROOT/media/" "$local_steam_42/media/"
    cp "$ROOT/mod.info" "$local_steam_42/mod.info"
    [ -f "$ROOT/poster.png" ] && cp "$ROOT/poster.png" "$local_steam_42/poster.png"
    echo "  [$MOD_ID] local → $local_steam_42 (Steam content)"
fi

# ── Место 2: удалённый хост lena ─────────────────────────────────────────────
if $DEPLOY_LENA && ssh_available; then
    r_ws_root="$REMOTE_WS_BASE/$MOD_ID"
    r_ws_42="$r_ws_root/Contents/mods/$MOD_ID/42"
    r_local_42="$REMOTE_LOCAL_BASE/$MOD_ID/42"

    ssh "$REMOTE_HOST" "mkdir -p '$r_ws_root'"
    rsync -a "$ROOT/workshop.txt" "$REMOTE_HOST:$r_ws_root/workshop.txt"
    [ -f "$ROOT/preview.png" ] && rsync -a "$ROOT/preview.png" "$REMOTE_HOST:$r_ws_root/preview.png"

    sync_42_remote "$r_ws_42"
    sync_42_remote "$r_local_42"
    echo "  [$MOD_ID] $REMOTE_HOST → $r_ws_42"
    echo "  [$MOD_ID] $REMOTE_HOST → $r_local_42"

    r_steam_42=$(ssh "$REMOTE_HOST" \
        "grep -rl '^id=$MOD_ID\$' '/home/tony/.local/share/Steam/steamapps/workshop/content/108600/' 2>/dev/null \
         | grep '/mod\.info$' | head -1 | xargs dirname 2>/dev/null" || true)
    if [ -n "$r_steam_42" ]; then
        rsync -a --delete "$ROOT/media/" "$REMOTE_HOST:$r_steam_42/media/"
        rsync -a "$ROOT/mod.info" "$REMOTE_HOST:$r_steam_42/mod.info"
        [ -f "$ROOT/poster.png" ] && rsync -a "$ROOT/poster.png" "$REMOTE_HOST:$r_steam_42/poster.png"
        echo "  [$MOD_ID] $REMOTE_HOST → $r_steam_42 (Steam content)"
    fi
elif $DEPLOY_LENA; then
    echo "  [$MOD_ID] $REMOTE_HOST недоступен, пропускаю"
fi

echo "=== Готово. Перезапусти игру ==="
