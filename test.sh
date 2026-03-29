#!/usr/bin/env bash
# test.sh — копирует мод в Steam workshop content для тестирования.
#
# Использование:
#   ./test.sh        — только копирование файлов
#   ./test.sh --run  — копирование + запуск PZ в debug-режиме

set -euo pipefail

MOD_ID="We"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HOME/.local/share/Steam/steamapps/workshop/content/108600/3695109540/mods/$MOD_ID/42"
PZ_BIN="$HOME/.local/share/Steam/steamapps/common/ProjectZomboid/projectzomboid/ProjectZomboid64"

echo "[We] Синхронизация в Steam workshop..."
echo "  Источник   : $SRC_DIR"
echo "  Назначение : $DEST_DIR"
echo ""

rsync -av --delete \
    --include="mod.info" \
    --include="poster.png" \
    --include="media/" \
    --include="media/**" \
    --exclude="*" \
    "$SRC_DIR/" "$DEST_DIR/"

echo ""
echo "[We] Готово."

if [[ "${1:-}" == "--run" ]]; then
    if [[ ! -x "$PZ_BIN" ]]; then
        echo "[We] Ошибка: не найден PZ: $PZ_BIN"
        exit 1
    fi
    echo "[We] Запуск PZ в debug-режиме..."
    cd "$(dirname "$PZ_BIN")"
    ./ProjectZomboid64 -debug &
fi
