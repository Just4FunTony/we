#!/bin/bash
set -e

ROOT="$(dirname "$0")"
SRC="$ROOT/media/lua"

# Keep all likely load locations synchronized.
TARGETS=(
    "/home/tony/Zomboid/Workshop/We/Contents/mods/We/42/media/lua"
    "/home/tony/.local/share/Steam/steamapps/workshop/content/108600/3695109540/mods/We/42/media/lua"
    "/home/tony/Zomboid/mods/We/42/media/lua"
)

sync_lua_tree() {
    local dst="$1"
    mkdir -p "$dst"

    # Mirror source tree to avoid stale translation files.
    rm -rf "$dst/client" "$dst/server" "$dst/shared"
    mkdir -p "$dst/client" "$dst/server" "$dst/shared"
    cp -r "$SRC/client/." "$dst/client/"
    cp -r "$SRC/server/." "$dst/server/"
    cp -r "$SRC/shared/." "$dst/shared/"

    # Hard cleanup of deprecated translation files.
    rm -f "$dst/shared/Translate/EN/UI_We.json" "$dst/shared/Translate/RU/UI_We.json" 2>/dev/null || true
    rm -f "$dst/shared/Translate/EN/UI_We_EN.txt" "$dst/shared/Translate/RU/UI_We_RU.txt" 2>/dev/null || true

    echo "Deployed to $dst"
}

for dst in "${TARGETS[@]}"; do
    sync_lua_tree "$dst"
done
