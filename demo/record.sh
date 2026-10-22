#!/bin/sh
# Regenerates the README demos in docs/ from demo/record.lua (needs lua5.4, lgi, ffmpeg).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../docs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

# record <name> <mode> <fps> <seconds> <gif width>
record() {
  mkdir -p "$tmp/$1" "$tmp/home"
  rm -rf "$tmp/home/.claude"
  HOME="$tmp/home" lua5.4 "$here/record.lua" "$tmp/$1" "$2" 1600 900 "$3" "$4"
  ffmpeg -loglevel error -y -framerate "$3" -i "$tmp/$1/%05d.png" \
    -vf "scale=$5:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
    "$out/$1.gif"
  cp "$tmp/$1/$(ls "$tmp/$1" | sed -n "$(( $3 * 8 ))p")" "$out/$1.png"
}

record constellation wallpaper 15 12 960
record lock lock 15 8 800
ls -la "$out"
