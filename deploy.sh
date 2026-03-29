#!/usr/bin/env bash
# deploy.sh — копирует мод "We" в папку модов PZ и опционально запускает игру.
#
# Использование:
#   ./deploy.sh          — только копирование файлов
#   ./deploy.sh --run    — копирование + запуск PZ в debug-режиме
#   ./deploy.sh --clean  — удалить установленный мод

set -euo pipefail

MOD_ID="We"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
MODS_DIR="$HOME/Zomboid/Workshop"
DEST_DIR="$MODS_DIR/$MOD_ID/Contents/mods/$MOD_ID/42"
ROOT_DIR="$MODS_DIR/$MOD_ID"
PZ_BIN="$HOME/.local/share/Steam/steamapps/common/ProjectZomboid/projectzomboid/ProjectZomboid64"

# ── --clean ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--clean" ]]; then
    if [[ -d "$MODS_DIR/$MOD_ID" ]]; then
        rm -rf "$MODS_DIR/$MOD_ID"
        echo "[We] Мод удалён: $MODS_DIR/$MOD_ID"
    else
        echo "[We] Мод не установлен."
    fi
    exit 0
fi

# ── Копирование файлов ────────────────────────────────────────────────────────
echo "[We] Синхронизация файлов..."
echo "  Источник : $SRC_DIR"
echo "  Назначение: $DEST_DIR"
echo ""

mkdir -p "$DEST_DIR"

rsync -av --delete \
    --include="mod.info" \
    --include="poster.png" \
    --include="media/" \
    --include="media/**" \
    --exclude="*" \
    "$SRC_DIR/" "$DEST_DIR/"

# preview.png и workshop.txt — в корне Workshop/We/
for f in preview.png workshop.txt; do
    [[ -f "$SRC_DIR/$f" ]] && cp "$SRC_DIR/$f" "$ROOT_DIR/$f"
done

echo ""
echo "[We] Готово. Файлы скопированы в $DEST_DIR"

# ── --run ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--run" ]]; then
    if [[ ! -x "$PZ_BIN" ]]; then
        echo "[We] Ошибка: не найден исполняемый файл PZ: $PZ_BIN"
        exit 1
    fi

    echo ""
    echo "[We] Запуск Project Zomboid в debug-режиме..."
    echo "     Горячая перезагрузка Lua: в игре откройте консоль (F12 / ~ в debug-режиме)"
    echo "     и введите: reloadLua()"
    echo ""

    # Запуск из директории игры (PZ требует CWD = папка с бинарником)
    cd "$(dirname "$PZ_BIN")"
    ./ProjectZomboid64 -debug &
fi
