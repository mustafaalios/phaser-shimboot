#!/bin/bash
#download a board's RMA shim from cdn.cros.download and unzip it
#usage: tools/fetch_shim.sh board out.bin

set -e
board="$1"
out="$(realpath -m "$2")"
base="https://cdn.cros.download"
work="$(mktemp -d)"

path="$(curl -sSf "$base/boards.txt" | grep "/$board/").manifest"
dir="$(dirname "$path")"
chunks="$(curl -sSf "$base/$path" | python3 -I -c 'import json, sys; print("\n".join(json.load(sys.stdin)["chunks"]))')"
for chunk in $chunks; do
  curl -sSf --retry 4 "$base/$dir/$chunk" -o "$work/$chunk"
done
cat $(for chunk in $chunks; do echo "$work/$chunk"; done) > "$work/shim.zip"
unzip -p "$work/shim.zip" > "$out"
rm -rf "$work"
ls -l "$out"
