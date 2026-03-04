#!/usr/bin/env bash
set -euo pipefail

# sync.sh — Fetch PS1 artwork from upstream sources, organize by serial number.
# Idempotent: skips existing files unless --force is passed.
# Requires: git, ImageMagick (convert/magick), curl

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
mkdir -p "$CACHE" "$ROOT/covers" "$ROOT/screenshots" "$ROOT/titles"

# ── Detect ImageMagick command ──────────────────────────────────────────────
if command -v magick &>/dev/null; then
  CONVERT="magick"
elif command -v convert &>/dev/null; then
  CONVERT="convert"
else
  echo "ERROR: ImageMagick not found. Install it: brew install imagemagick" >&2
  exit 1
fi

# ── Clone / update source repos (shallow) ───────────────────────────────────
clone_or_pull() {
  local url="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    echo "Updating $dir ..."
    git -C "$dir" pull --ff-only --depth=1 2>/dev/null || true
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

# ── Parse DAT file: build serial → game name map ───────────────────────────
# Output: tab-separated lines of SERIAL\tNAME
declare -A SERIAL_MAP
current_name=""
while IFS= read -r line; do
  # Match name lines
  if [[ "$line" =~ ^[[:space:]]*name[[:space:]]+\"(.+)\" ]]; then
    current_name="${BASH_REMATCH[1]}"
  fi
  # Match serial lines — can contain multiple serials separated by commas/spaces
  if [[ "$line" =~ ^[[:space:]]*serial[[:space:]]+\"(.+)\" ]]; then
    raw_serials="${BASH_REMATCH[1]}"
    # Some entries have comma-separated serials; split on comma and trim
    IFS=',' read -ra parts <<< "$raw_serials"
    for part in "${parts[@]}"; do
      serial="$(echo "$part" | xargs)" # trim whitespace
      if [[ -n "$serial" && -n "$current_name" ]]; then
        SERIAL_MAP["$serial"]="$current_name"
      fi
    done
  fi
done < "$DAT"

echo "Parsed ${#SERIAL_MAP[@]} serial→name mappings"

# ── Helper: encode game name to libretro-thumbnails filename ────────────────
# Characters &*/:\`<>?| are replaced with _ in filenames
encode_name() {
  local name="$1"
  echo "$name" | sed 's/[&*\/:\\<>?|]/_/g'
}

# ── 1. Copy covers ─────────────────────────────────────────────────────────
echo ""
echo "=== Copying covers ==="
covers_copied=0
covers_skipped=0
covers_dir="$CACHE/psx-covers/covers/default"
if [[ -d "$covers_dir" ]]; then
  for src in "$covers_dir"/*.jpg; do
    [[ -f "$src" ]] || continue
    filename="$(basename "$src")"
    dest="$ROOT/covers/$filename"
    if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
      ((covers_skipped++))
      continue
    fi
    cp "$src" "$dest"
    ((covers_copied++))
  done
fi
echo "Covers: $covers_copied copied, $covers_skipped skipped (already exist)"

# ── 2. Convert screenshots (Named_Snaps) ───────────────────────────────────
echo ""
echo "=== Processing screenshots ==="
snaps_found=0
snaps_skipped=0
snaps_missing=0
for serial in "${!SERIAL_MAP[@]}"; do
  name="${SERIAL_MAP[$serial]}"
  encoded="$(encode_name "$name")"
  src="$CACHE/libretro-thumbnails/Named_Snaps/${encoded}.png"
  dest="$ROOT/screenshots/${serial}.jpg"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((snaps_skipped++))
    continue
  fi

  if [[ -f "$src" ]]; then
    $CONVERT "$src" -quality 85 "$dest"
    ((snaps_found++))
  else
    ((snaps_missing++))
  fi
done
echo "Screenshots: $snaps_found converted, $snaps_skipped skipped, $snaps_missing missing upstream"

# ── 3. Convert titles (Named_Titles) ───────────────────────────────────────
echo ""
echo "=== Processing titles ==="
titles_found=0
titles_skipped=0
titles_missing=0
for serial in "${!SERIAL_MAP[@]}"; do
  name="${SERIAL_MAP[$serial]}"
  encoded="$(encode_name "$name")"
  src="$CACHE/libretro-thumbnails/Named_Titles/${encoded}.png"
  dest="$ROOT/titles/${serial}.jpg"

  if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
    ((titles_skipped++))
    continue
  fi

  if [[ -f "$src" ]]; then
    $CONVERT "$src" -quality 85 "$dest"
    ((titles_found++))
  else
    ((titles_missing++))
  fi
done
echo "Titles: $titles_found converted, $titles_skipped skipped, $titles_missing missing upstream"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Serial mappings: ${#SERIAL_MAP[@]}"
echo "Covers:      $((covers_copied + covers_skipped)) total"
echo "Screenshots: $((snaps_found + snaps_skipped)) found"
echo "Titles:      $((titles_found + titles_skipped)) found"
echo "Done."
