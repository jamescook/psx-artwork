#!/usr/bin/env bash
set -euo pipefail

# sync.sh — Fetch PS1 artwork from upstream sources, organize by serial number.
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
else
  # Verify cache dirs exist for serial mode
  for d in "$CACHE/psx-covers" "$CACHE/libretro-thumbnails"; do
    if [[ ! -d "$d" ]]; then
      echo "Cache not found: $d — run a full sync first" >&2
      exit 1
    fi
  done
fi

# ── Fetch DAT file ──────────────────────────────────────────────────────────
DAT="$CACHE/Sony - PlayStation.dat"
if [[ -z "$SERIAL_FILTER" ]] || [[ ! -f "$DAT" ]]; then
  echo "Fetching serial→name DAT file ..."
  curl -sL "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/Sony%20-%20PlayStation.dat" -o "$DAT"
fi

# ── Parse DAT file: build serial→name TSV ───────────────────────────────────
MAP_FILE="$CACHE/serial_map.tsv"
if [[ -z "$SERIAL_FILTER" ]] || [[ ! -f "$MAP_FILE" ]]; then
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
fi

map_count=$(wc -l < "$MAP_FILE" | tr -d ' ')
echo "Parsed $map_count serial→name mappings"

# When filtering by serial, pre-filter the map to matching entries only
if [[ -n "$SERIAL_FILTER" ]]; then
  filter_hyph="$(echo "$SERIAL_FILTER" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
  FILTERED_MAP="$CACHE/serial_map_filtered.tsv"
  grep "^${filter_hyph}" "$MAP_FILE" > "$FILTERED_MAP" || true
  filtered_count=$(wc -l < "$FILTERED_MAP" | tr -d ' ')
  echo "Filtered to $filtered_count entries matching $SERIAL_FILTER"
  MAP_FILE="$FILTERED_MAP"
  map_count="$filtered_count"
fi

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

# ── 1. Copy covers (with nesting) ─────────────────────────────────────────
echo ""
echo "=== Syncing covers ==="
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
  for src in "${cover_files[@]}"; do
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

# ── 2. Convert screenshots (Named_Snaps) ───────────────────────────────────
echo ""
echo "=== Processing screenshots ==="
snaps_found=0
snaps_skipped=0
snaps_missing=0
snaps_i=0
while IFS=$'\t' read -r serial name; do
  ((snaps_i++)) || true
  printf "\r\033[K  [%d/%d] %s" "$snaps_i" "$map_count" "$serial"

  encoded="$(encode_name "$name")"
  dest="$(serial_dest_path "screenshots" "$serial")"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((snaps_skipped++)) || true
    [[ "$DRY_RUN" == true ]] && echo "  SKIP (exists): $dest"
    continue
  fi

  if src="$(find_thumbnail "$CACHE/libretro-thumbnails/Named_Snaps" "$encoded" "$name")"; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  CONVERT: $src → $dest"
      ((snaps_found++)) || true
    elif $CONVERT "$src" -quality 85 "$dest" 2>/dev/null; then
      ((snaps_found++)) || true
    else
      echo ""
      echo "  WARN: failed to convert $src"
      ((snaps_missing++)) || true
    fi
  else
    ((snaps_missing++)) || true
    [[ "$DRY_RUN" == true ]] && echo "  MISS: $serial ($name) — encoded: $encoded"
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
  printf "\r\033[K  [%d/%d] %s" "$titles_i" "$map_count" "$serial"

  encoded="$(encode_name "$name")"
  dest="$(serial_dest_path "titles" "$serial")"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((titles_skipped++)) || true
    [[ "$DRY_RUN" == true ]] && echo "  SKIP (exists): $dest"
    continue
  fi

  if src="$(find_thumbnail "$CACHE/libretro-thumbnails/Named_Titles" "$encoded" "$name")"; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  CONVERT: $src → $dest"
      ((titles_found++)) || true
    elif $CONVERT "$src" -quality 85 "$dest" 2>/dev/null; then
      ((titles_found++)) || true
    else
      echo ""
      echo "  WARN: failed to convert $src"
      ((titles_missing++)) || true
    fi
  else
    ((titles_missing++)) || true
    [[ "$DRY_RUN" == true ]] && echo "  MISS: $serial ($name) — encoded: $encoded"
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
[[ "$DRY_RUN" == true ]] && echo "(dry-run — no files were written)"
echo "Done."
