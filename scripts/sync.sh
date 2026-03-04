#!/usr/bin/env bash
set -euo pipefail

# sync.sh — Fetch PS1 artwork from upstream sources, organize by serial number.
# Idempotent: skips existing files unless --force is passed.
# Requires: git, ImageMagick (convert/magick), curl, rsync
# Compatible with bash 3.2+ (macOS default).
#
# Output structure (two-level nesting to keep directories browsable):
#   {category}/{PREFIX}/{DIGITS}/{SERIAL}.jpg
#   e.g. covers/SLUS/008/SLUS-00896.jpg
#
# PREFIX = letters before the hyphen (SLUS, SCES, etc.)
# DIGITS = first 3 digits after the hyphen (008, 941, etc.)

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
mkdir -p "$CACHE"

# ── Detect ImageMagick command ──────────────────────────────────────────────
if command -v magick &>/dev/null; then
  CONVERT="magick"
elif command -v convert &>/dev/null; then
  CONVERT="convert"
else
  echo "ERROR: ImageMagick not found. Install it: brew install imagemagick" >&2
  exit 1
fi

# ── Helper: build nested output path for a serial ──────────────────────────
# serial_dest_path "covers" "SLUS-00896" → covers/SLUS/008/SLUS-00896.jpg
serial_dest_path() {
  local category="$1" serial="$2"
  local prefix="${serial%%-*}"
  local after="${serial#*-}"
  local digits="${after:0:3}"
  local dir="$ROOT/$category/$prefix/$digits"
  mkdir -p "$dir"
  echo "$dir/${serial}.jpg"
}

# ── Clone / update source repos (shallow) ───────────────────────────────────
clone_or_pull() {
  local url="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    echo "Updating $dir ..."
    git -C "$dir" fetch --depth=1 origin 2>/dev/null || true
    git -C "$dir" reset --hard origin/HEAD 2>/dev/null || true
  else
    echo "Cloning $url ..."
    git clone --depth=1 "$url" "$dir"
  fi
}

clone_or_pull "https://github.com/xlenore/psx-covers.git" "$CACHE/psx-covers"
clone_or_pull "https://github.com/libretro-thumbnails/Sony_-_PlayStation.git" "$CACHE/libretro-thumbnails"

# ── Fetch DAT file ──────────────────────────────────────────────────────────
DAT="$CACHE/Sony - PlayStation.dat"
echo "Fetching serial→name DAT file ..."
curl -sL "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/Sony%20-%20PlayStation.dat" -o "$DAT"

# ── Parse DAT file: build serial→name TSV ───────────────────────────────────
MAP_FILE="$CACHE/serial_map.tsv"
awk '
  /^[[:space:]]*name[[:space:]]+"/ {
    sub(/^[^"]*"/, "")
    sub(/"[^"]*$/, "")
    name = $0
  }
  /^[[:space:]]*serial[[:space:]]+"/ {
    sub(/^[^"]*"/, "")
    sub(/"[^"]*$/, "")
    n = split($0, serials, ",")
    for (i = 1; i <= n; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", serials[i])
      if (serials[i] != "" && name != "") {
        gsub(/\//, "_", serials[i])
        print serials[i] "\t" name
      }
    }
  }
' "$DAT" > "$MAP_FILE"

map_count=$(wc -l < "$MAP_FILE" | tr -d ' ')
echo "Parsed $map_count serial→name mappings"

# ── Helper: encode game name to libretro-thumbnails filename ────────────────
# Characters &*/:\`<>?| are replaced with _ in filenames
encode_name() {
  echo "$1" | sed 's/[&*\/:\\<>?|]/_/g'
}

# ── 1. Copy covers (with nesting) ─────────────────────────────────────────
echo ""
echo "=== Syncing covers ==="
covers_dir="$CACHE/psx-covers/covers/default"
covers_copied=0
covers_skipped=0
covers_i=0
if [[ -d "$covers_dir" ]]; then
  covers_total=$(find "$covers_dir" -name '*.jpg' | wc -l | tr -d ' ')
  for src in "$covers_dir"/*.jpg; do
    [[ -f "$src" ]] || continue
    ((covers_i++)) || true
    serial="$(basename "$src" .jpg)"
    printf "\r  [%d/%d] %s" "$covers_i" "$covers_total" "$serial"
    dest="$(serial_dest_path "covers" "$serial")"

    if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
      ((covers_skipped++)) || true
      continue
    fi
    cp "$src" "$dest"
    ((covers_copied++)) || true
  done
  echo ""
fi
echo "Covers: $covers_copied copied, $covers_skipped skipped"

# ── 2. Convert screenshots (Named_Snaps) ───────────────────────────────────
echo ""
echo "=== Processing screenshots ==="
snaps_found=0
snaps_skipped=0
snaps_missing=0
snaps_i=0
while IFS=$'\t' read -r serial name; do
  ((snaps_i++)) || true
  printf "\r  [%d/%d] %s" "$snaps_i" "$map_count" "$serial"

  encoded="$(encode_name "$name")"
  src="$CACHE/libretro-thumbnails/Named_Snaps/${encoded}.png"
  dest="$(serial_dest_path "screenshots" "$serial")"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((snaps_skipped++)) || true
    continue
  fi

  if [[ -f "$src" ]]; then
    if $CONVERT "$src" -quality 85 "$dest" 2>/dev/null; then
      ((snaps_found++)) || true
    else
      echo ""
      echo "  WARN: failed to convert $src"
      ((snaps_missing++)) || true
    fi
  else
    ((snaps_missing++)) || true
  fi
done < "$MAP_FILE"
echo ""
echo "Screenshots: $snaps_found converted, $snaps_skipped skipped, $snaps_missing missing/failed upstream"

# ── 3. Convert titles (Named_Titles) ───────────────────────────────────────
echo ""
echo "=== Processing titles ==="
titles_found=0
titles_skipped=0
titles_missing=0
titles_i=0
while IFS=$'\t' read -r serial name; do
  ((titles_i++)) || true
  printf "\r  [%d/%d] %s" "$titles_i" "$map_count" "$serial"

  encoded="$(encode_name "$name")"
  src="$CACHE/libretro-thumbnails/Named_Titles/${encoded}.png"
  dest="$(serial_dest_path "titles" "$serial")"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((titles_skipped++)) || true
    continue
  fi

  if [[ -f "$src" ]]; then
    if $CONVERT "$src" -quality 85 "$dest" 2>/dev/null; then
      ((titles_found++)) || true
    else
      echo ""
      echo "  WARN: failed to convert $src"
      ((titles_missing++)) || true
    fi
  else
    ((titles_missing++)) || true
  fi
done < "$MAP_FILE"
echo ""
echo "Titles: $titles_found converted, $titles_skipped skipped, $titles_missing missing/failed upstream"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Serial mappings: $map_count"
echo "Covers:      $((covers_copied + covers_skipped)) total"
echo "Screenshots: $((snaps_found + snaps_skipped)) found of $map_count"
echo "Titles:      $((titles_found + titles_skipped)) found of $map_count"
echo "Done."
