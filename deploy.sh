#!/bin/bash
SRC="$(dirname "$0")/media/lua"
DST1="/home/tony/Zomboid/Workshop/We/Contents/mods/We/42/media/lua"
DST2="/home/tony/.local/share/Steam/steamapps/workshop/content/108600/3695109540/mods/We/42/media/lua"

for DST in "$DST1" "$DST2"; do
    if [ -d "$DST" ]; then
        cp "$SRC"/client/*.lua "$DST/client/"
        cp "$SRC"/server/*.lua "$DST/server/"
        cp "$SRC"/shared/*.lua "$DST/shared/"
        echo "Deployed to $DST"
    fi
done
