#!/usr/bin/env bash
set -euo pipefail

# sync.sh — Fetch PS1 and PSP artwork from upstream sources, organize by serial number.
# Idempotent: skips existing files unless --force is passed.
# Requires: git, ImageMagick (convert/magick), curl, rsync
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   scripts/sync.sh                      # Full sync
#   scripts/sync.sh --serial SLUS-01251  # Single serial (skips clone/fetch)
#   scripts/sync.sh --serial SLUS-01251 --dry-run  # Show what would happen
#   scripts/sync.sh --force              # Re-sync everything
#
# Output structure (two-level nesting to keep directories browsable):
#   {category}/{PREFIX}/{DIGITS}/{SERIAL}.jpg
#   e.g. covers/SLUS/008/SLUS-00896.jpg
#
# PREFIX = letters before the hyphen (SLUS, SCES, etc.)
# DIGITS = first 3 digits after the hyphen (008, 941, etc.)
#
# PS1 and PSP share the same tree. Their serials never collide (PSP uses
# ULUS, ULES, ULJM, UCUS, ... prefixes), so consumers keyed by serial need
# no platform switch.

FORCE=false
SERIAL_FILTER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=true; shift ;;
    --serial)  SERIAL_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

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
  [[ "$DRY_RUN" == false ]] && mkdir -p "$dir"
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

# Skip network fetches for single-serial lookups if cache already exists
if [[ -z "$SERIAL_FILTER" ]]; then
  clone_or_pull "https://github.com/xlenore/psx-covers.git" "$CACHE/psx-covers"
  clone_or_pull "https://github.com/libretro-thumbnails/Sony_-_PlayStation.git" "$CACHE/libretro-thumbnails"
  clone_or_pull "https://github.com/libretro-thumbnails/Sony_-_PlayStation_Portable.git" "$CACHE/libretro-thumbnails-psp"
else
  # Verify cache dirs exist for serial mode
  for d in "$CACHE/psx-covers" "$CACHE/libretro-thumbnails" "$CACHE/libretro-thumbnails-psp"; do
    if [[ ! -d "$d" ]]; then
      echo "Cache not found: $d — run a full sync first" >&2
      exit 1
    fi
  done
fi

# ── Helper: fetch a redump DAT file ─────────────────────────────────────────
fetch_dat() {
  local system="$1" dat="$2"
  if [[ -z "$SERIAL_FILTER" ]] || [[ ! -f "$dat" ]]; then
    echo "Fetching $system serial→name DAT file ..."
    curl -sL "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/${system// /%20}.dat" -o "$dat"
  fi
}

# ── Helper: parse a DAT file into a serial→name TSV ─────────────────────────
build_serial_map() {
  local dat="$1" map="$2"
  if [[ -z "$SERIAL_FILTER" ]] || [[ ! -f "$map" ]]; then
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
    ' "$dat" > "$map"
  fi
}

# ── Helper: narrow a map to the --serial filter ─────────────────────────────
# Prints the path of the map to use.
filter_map() {
  local map="$1"
  if [[ -z "$SERIAL_FILTER" ]]; then
    echo "$map"
    return
  fi
  local filter_hyph filtered="${map%.tsv}_filtered.tsv"
  filter_hyph="$(echo "$SERIAL_FILTER" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
  grep "^${filter_hyph}" "$map" > "$filtered" || true
  echo "$filtered"
}

DAT="$CACHE/Sony - PlayStation.dat"
MAP_FILE="$CACHE/serial_map.tsv"
fetch_dat "Sony - PlayStation" "$DAT"
build_serial_map "$DAT" "$MAP_FILE"
MAP_FILE="$(filter_map "$MAP_FILE")"
map_count=$(wc -l < "$MAP_FILE" | tr -d ' ')
echo "Parsed $map_count PS1 serial→name mappings"

# PSP serials outside the usual ABCD-12345 shape (NW10107630, KOEI-P0177,
# HONEY-002, ...) are promo and dev discs; they would make odd directories
# and libretro has little art for them, so they are left out.
PSP_DAT="$CACHE/Sony - PlayStation Portable.dat"
PSP_MAP_FILE="$CACHE/serial_map_psp.tsv"
fetch_dat "Sony - PlayStation Portable" "$PSP_DAT"
build_serial_map "$PSP_DAT" "$PSP_MAP_FILE.all"
grep -E $'^[A-Z]{4}-[0-9]{5}\t' "$PSP_MAP_FILE.all" > "$PSP_MAP_FILE" || true
PSP_MAP_FILE="$(filter_map "$PSP_MAP_FILE")"
psp_map_count=$(wc -l < "$PSP_MAP_FILE" | tr -d ' ')
echo "Parsed $psp_map_count PSP serial→name mappings"

# ── Helper: encode game name to libretro-thumbnails filename ────────────────
# Characters &*/:\`<>?| are replaced with _ in filenames
encode_name() {
  echo "$1" | sed 's/[&*\/:\\<>?|]/_/g'
}

# ── Helper: find thumbnail file, with region fallback ─────────────────────
# Redump DAT uses compound regions like "USA, Canada" but libretro-thumbnails
# often uses the simplified form "USA". Try exact match first, then strip the
# second region from compound entries.
find_thumbnail() {
  local dir="$1" encoded="$2" name="$3"
  local src="$dir/${encoded}.png"
  if [[ -f "$src" ]]; then
    echo "$src"
    return 0
  fi
  # Try stripping second region: "Game (USA, Canada) ..." → "Game (USA) ..."
  local simplified
  simplified="$(echo "$name" | sed 's/(\([A-Za-z]*\), [A-Za-z]*)/(\1)/')"
  if [[ "$simplified" != "$name" ]]; then
    local alt_encoded
    alt_encoded="$(encode_name "$simplified")"
    src="$dir/${alt_encoded}.png"
    if [[ -f "$src" ]]; then
      echo "$src"
      return 0
    fi
  fi
  return 1
}

# ── Helper: check if serial matches filter ──────────────────────────────────
matches_filter() {
  [[ -z "$SERIAL_FILTER" ]] && return 0
  # Normalize both to hyphenated form for comparison
  local filter_norm serial_norm
  filter_norm="$(echo "$SERIAL_FILTER" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
  serial_norm="$(echo "$1" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
  [[ "$serial_norm" == "$filter_norm"* ]]
}

# ── Helper: convert libretro thumbnails for every serial in a map ──────────
# convert_thumbnails "screenshots" "$CACHE/libretro-thumbnails/Named_Snaps" "$MAP_FILE"
# Sets conv_found, conv_skipped and conv_missing.
convert_thumbnails() {
  local category="$1" thumbs_dir="$2" map="$3"
  local total i=0 serial name encoded dest src
  total=$(wc -l < "$map" | tr -d ' ')
  conv_found=0
  conv_skipped=0
  conv_missing=0
  while IFS=$'\t' read -r serial name; do
    ((i++)) || true
    printf "\r\033[K  [%d/%d] %s" "$i" "$total" "$serial"

    encoded="$(encode_name "$name")"
    dest="$(serial_dest_path "$category" "$serial")"

    if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
      ((conv_skipped++)) || true
      [[ "$DRY_RUN" == true ]] && echo "  SKIP (exists): $dest"
      continue
    fi

    if src="$(find_thumbnail "$thumbs_dir" "$encoded" "$name")"; then
      if [[ "$DRY_RUN" == true ]]; then
        echo "  CONVERT: $src → $dest"
        ((conv_found++)) || true
      elif $CONVERT "$src" -quality 85 "$dest" 2>/dev/null; then
        ((conv_found++)) || true
      else
        echo ""
        echo "  WARN: failed to convert $src"
        ((conv_missing++)) || true
      fi
    else
      ((conv_missing++)) || true
      [[ "$DRY_RUN" == true ]] && echo "  MISS: $serial ($name) — encoded: $encoded"
    fi
  done < "$map"
  echo ""
}

# ── 1. Copy PS1 covers (with nesting) ─────────────────────────────────────
echo ""
echo "=== Syncing PS1 covers ==="
covers_dir="$CACHE/psx-covers/covers/default"
covers_copied=0
covers_skipped=0
covers_i=0
if [[ -d "$covers_dir" ]]; then
  if [[ -n "$SERIAL_FILTER" ]]; then
    # Normalize filter to hyphenated
    filter_hyph="$(echo "$SERIAL_FILTER" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
    covers_total=1
    # Try exact match and prefix match (for multi-disc suffixes)
    cover_files=()
    for f in "$covers_dir/${filter_hyph}"*.jpg; do
      [[ -f "$f" ]] && cover_files+=("$f")
    done
    covers_total=${#cover_files[@]}
  else
    covers_total=$(find "$covers_dir" -name '*.jpg' | wc -l | tr -d ' ')
    cover_files=("$covers_dir"/*.jpg)
  fi
  for src in "${cover_files[@]+"${cover_files[@]}"}"; do
    [[ -f "$src" ]] || continue
    ((covers_i++)) || true
    serial="$(basename "$src" .jpg)"
    if [[ -n "$SERIAL_FILTER" ]] && ! matches_filter "$serial"; then
      continue
    fi
    printf "\r\033[K  [%d/%d] %s" "$covers_i" "$covers_total" "$serial"
    dest="$(serial_dest_path "covers" "$serial")"

    if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
      ((covers_skipped++)) || true
      [[ "$DRY_RUN" == true ]] && echo "  SKIP (exists): $dest"
      continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      echo "  COPY: $src → $dest"
    else
      cp "$src" "$dest"
    fi
    ((covers_copied++)) || true
  done
  echo ""
fi
echo "Covers: $covers_copied copied, $covers_skipped skipped"

# ── 2. Convert PS1 screenshots (Named_Snaps) ───────────────────────────────
echo ""
echo "=== Processing PS1 screenshots ==="
convert_thumbnails "screenshots" "$CACHE/libretro-thumbnails/Named_Snaps" "$MAP_FILE"
snaps_found=$conv_found; snaps_skipped=$conv_skipped
echo "Screenshots: $conv_found converted, $conv_skipped skipped, $conv_missing missing/failed upstream"

# ── 3. Convert PS1 titles (Named_Titles) ───────────────────────────────────
echo ""
echo "=== Processing PS1 titles ==="
convert_thumbnails "titles" "$CACHE/libretro-thumbnails/Named_Titles" "$MAP_FILE"
titles_found=$conv_found; titles_skipped=$conv_skipped
echo "Titles: $conv_found converted, $conv_skipped skipped, $conv_missing missing/failed upstream"

# ── 4. Convert PSP covers, screenshots and titles ─────────────────────────
# xlenore has no PSP cover set, so PSP covers come from libretro's boxarts.
echo ""
echo "=== Processing PSP covers ==="
convert_thumbnails "covers" "$CACHE/libretro-thumbnails-psp/Named_Boxarts" "$PSP_MAP_FILE"
psp_covers=$((conv_found + conv_skipped))
echo "Covers: $conv_found converted, $conv_skipped skipped, $conv_missing missing/failed upstream"

echo ""
echo "=== Processing PSP screenshots ==="
convert_thumbnails "screenshots" "$CACHE/libretro-thumbnails-psp/Named_Snaps" "$PSP_MAP_FILE"
psp_snaps=$((conv_found + conv_skipped))
echo "Screenshots: $conv_found converted, $conv_skipped skipped, $conv_missing missing/failed upstream"

echo ""
echo "=== Processing PSP titles ==="
convert_thumbnails "titles" "$CACHE/libretro-thumbnails-psp/Named_Titles" "$PSP_MAP_FILE"
psp_titles=$((conv_found + conv_skipped))
echo "Titles: $conv_found converted, $conv_skipped skipped, $conv_missing missing/failed upstream"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "PS1 serial mappings: $map_count"
echo "  Covers:      $((covers_copied + covers_skipped)) total"
echo "  Screenshots: $((snaps_found + snaps_skipped)) found of $map_count"
echo "  Titles:      $((titles_found + titles_skipped)) found of $map_count"
echo "PSP serial mappings: $psp_map_count"
echo "  Covers:      $psp_covers found of $psp_map_count"
echo "  Screenshots: $psp_snaps found of $psp_map_count"
echo "  Titles:      $psp_titles found of $psp_map_count"
[[ "$DRY_RUN" == true ]] && echo "(dry-run — no files were written)"
echo "Done."
