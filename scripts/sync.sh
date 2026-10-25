#!/usr/bin/env bash
set -euo pipefail

# sync.sh — Fetch PS1 and PSP artwork from upstream sources, organize by serial number.
# Idempotent: skips outputs whose upstream image is unchanged unless --force is passed.
# Requires: git, ImageMagick (convert/magick), curl
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   scripts/sync.sh                      # Full sync
#   scripts/sync.sh --serial SLUS-01251  # Single serial (skips upstream updates)
#   scripts/sync.sh --serial SLUS-01251 --dry-run  # Show what would happen
#   scripts/sync.sh --force              # Re-sync everything
#   scripts/sync.sh --prune              # Also delete orphaned outputs
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
#
# Upstream repos are cloned without file contents (--filter=blob:none): a
# clone holds only the file list and each file's git blob hash, a few MB.
# manifest.tsv records which upstream blob every output was made from, so a
# run fetches just the images that are new or changed upstream. A clone that
# fetched images is deleted at the end of the run; .cache/ is always safe to
# delete.

FORCE=false
SERIAL_FILTER=""
DRY_RUN=false
PRUNE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=true; shift ;;
    --serial)  SERIAL_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --prune)   PRUNE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
GIT_CACHE="$CACHE/git"
WORK="$CACHE/work"
MANIFEST="$ROOT/manifest.tsv"
mkdir -p "$GIT_CACHE" "$WORK"

# Normalize the filter to hyphenated form: SLUS01251 → SLUS-01251
if [[ -n "$SERIAL_FILTER" ]]; then
  SERIAL_FILTER="$(echo "$SERIAL_FILTER" | sed 's/\([A-Z]*\)\([0-9]\)/\1-\2/' | sed 's/--/-/')"
fi

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

# ── Upstream repos (blobless, shallow) ──────────────────────────────────────
# Each repo is named in the manifest by its directory under .cache/git/.
REPOS="psx-covers libretro-ps1 libretro-psp"
repo_url() {
  case "$1" in
    psx-covers)   echo "https://github.com/xlenore/psx-covers.git" ;;
    libretro-ps1) echo "https://github.com/libretro-thumbnails/Sony_-_PlayStation.git" ;;
    libretro-psp) echo "https://github.com/libretro-thumbnails/Sony_-_PlayStation_Portable.git" ;;
  esac
}

sync_repo() {
  local repo="$1" dir="$GIT_CACHE/$1"
  if [[ -d "$dir/.git" ]]; then
    # Single-serial runs reuse the file list they have
    [[ -n "$SERIAL_FILTER" ]] && return 0
    echo "Updating $repo ..."
    git -C "$dir" fetch -q --depth=1 --filter=blob:none origin
  else
    echo "Cloning $repo ..."
    git clone -q --filter=blob:none --no-checkout --depth=1 "$(repo_url "$repo")" "$dir"
  fi
}

# ── Helper: fetch blobs by hash, in batches, skipping ones already here ────
# fetch_blobs <clone dir> <file of hashes>
fetch_blobs() {
  local dir="$1" oids="$2" missing="$2.missing" chunk
  GIT_NO_LAZY_FETCH=1 git -C "$dir" cat-file --batch-check < "$oids" \
    | awk '$2 == "missing" { print $1 }' > "$missing"
  [[ -s "$missing" ]] || return 0
  rm -f "$missing".part.*
  split -l 5000 "$missing" "$missing.part."
  for chunk in "$missing".part.*; do
    git -C "$dir" -c fetch.negotiationAlgorithm=noop fetch -q --no-tags \
      --no-write-fetch-head --filter=blob:none origin --stdin < "$chunk"
  done
  rm -f "$missing".part.*
}

# ── Helper: list a repo's files as "path<TAB>blob" ─────────────────────────
# libretro-thumbnails stores many images as symlinks to another file. A
# symlink's blob holds its target path, so those small blobs are fetched and
# each symlink is listed with the blob of the file it points at.
list_files() {
  local repo="$1" out="$2" dir="$GIT_CACHE/$1"
  local raw="$out.raw" links="$out.links"
  git -C "$dir" ls-tree -r -z --full-tree origin/HEAD | tr '\0' '\n' > "$raw"
  awk -F'\t' '{ split($1, m, " ") } m[1] == "120000" { print m[3] }' "$raw" | sort -u > "$links"
  : > "$links.targets"
  if [[ -s "$links" ]]; then
    fetch_blobs "$dir" "$links"
    git -C "$dir" cat-file --batch < "$links" > "$links.targets"
  fi
  awk -F'\t' '
    function norm(p,   n, parts, out, i, k) {
      n = split(p, parts, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (k > 0) k--; continue }
        out[++k] = parts[i]
      }
      p = ""
      for (i = 1; i <= k; i++) p = p (i > 1 ? "/" : "") out[i]
      return p
    }
    function resolve(p,   depth, d) {
      for (depth = 0; depth < 8; depth++) {
        if (p in blob) return blob[p]
        if (!(p in link)) return ""
        d = p; sub(/[^\/]*$/, "", d)
        p = norm(d link[p])
      }
      return ""
    }
    # cat-file --batch: a "<hash> blob <size>" line, then the target path
    FILENAME == ARGV[1] {
      if (hash == "") { split($0, h, " "); hash = h[1]; next }
      target[hash] = $0; hash = ""; next
    }
    {
      split($1, m, " ")
      if (m[1] == "120000") link[$2] = target[m[3]]
      else if (m[2] == "blob") blob[$2] = m[3]
    }
    END {
      for (p in blob) print p "\t" blob[p]
      for (p in link) if ((b = resolve(p)) != "") print p "\t" b
    }
  ' "$links.targets" "$raw" > "$out"
}

# ── Fetch DAT files and build serial→name maps ─────────────────────────────
fetch_dat() {
  local system="$1" dat="$2"
  if [[ -z "$SERIAL_FILTER" ]] || [[ ! -f "$dat" ]]; then
    echo "Fetching $system serial→name DAT file ..."
    curl -sL "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/${system// /%20}.dat" -o "$dat"
  fi
}

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

DAT="$CACHE/Sony - PlayStation.dat"
MAP_FILE="$CACHE/serial_map.tsv"
fetch_dat "Sony - PlayStation" "$DAT"
build_serial_map "$DAT" "$MAP_FILE"
echo "Parsed $(wc -l < "$MAP_FILE" | tr -d ' ') PS1 serial→name mappings"

# PSP serials outside the usual ABCD-12345 shape (NW10107630, KOEI-P0177,
# HONEY-002, ...) are promo and dev discs; they would make odd directories
# and libretro has little art for them, so they are left out.
PSP_DAT="$CACHE/Sony - PlayStation Portable.dat"
PSP_MAP_FILE="$CACHE/serial_map_psp.tsv"
fetch_dat "Sony - PlayStation Portable" "$PSP_DAT"
build_serial_map "$PSP_DAT" "$PSP_MAP_FILE.all"
grep -E $'^[A-Z]{4}-[0-9]{5}\t' "$PSP_MAP_FILE.all" > "$PSP_MAP_FILE" || true
echo "Parsed $(wc -l < "$PSP_MAP_FILE" | tr -d ' ') PSP serial→name mappings"

# ── List upstream files ─────────────────────────────────────────────────────
for repo in $REPOS; do
  sync_repo "$repo"
  list_files "$repo" "$WORK/$repo.files"
done

# ── Match serials to upstream files ─────────────────────────────────────────
# Candidates are "category<TAB>serial<TAB>repo<TAB>path<TAB>blob", one per
# output; the first match for a category and serial wins.

# PS1 covers: xlenore names each file by serial
covers_candidates() {
  awk -F'\t' -v filter="$SERIAL_FILTER" '
    index($1, "covers/default/") == 1 && $1 ~ /\.jpg$/ {
      serial = substr($1, 16, length($1) - 19)
      if (index(serial, "/") || (filter != "" && index(serial, filter) != 1)) next
      print "covers\t" serial "\tpsx-covers\t" $1 "\t" $2
    }
  ' "$WORK/psx-covers.files"
}

# libretro_candidates <category> <repo> <dir> <map>
# libretro-thumbnails names each file by game name, with &*/:\<>?| replaced
# by _. Redump uses compound regions like "USA, Canada" where libretro often
# has just "USA", so a name with no exact match is retried with the second
# region stripped. Matching ignores case, as a macOS checkout did.
libretro_candidates() {
  awk -F'\t' -v cat="$1" -v repo="$2" -v dir="$3/" -v filter="$SERIAL_FILTER" '
    function enc(s,   o, i, c) {
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        o = o (index("&*/:\\<>?|", c) ? "_" : c)
      }
      return o
    }
    function lookup(stem) {
      if (stem in path) return stem
      if (tolower(stem) in lower) return lower[tolower(stem)]
      return ""
    }
    FILENAME == ARGV[1] {
      if (index($1, dir) != 1 || $1 !~ /\.png$/) next
      stem = substr($1, length(dir) + 1, length($1) - length(dir) - 4)
      if (index(stem, "/")) next
      path[stem] = $1; blob[stem] = $2
      if (!(tolower(stem) in lower)) lower[tolower(stem)] = stem
      next
    }
    {
      serial = $1; name = $2
      if (serial in done) next
      if (filter != "" && index(serial, filter) != 1) next
      stem = lookup(enc(name))
      if (stem == "" && match(name, /\([A-Za-z]*, [A-Za-z]*\)/)) {
        inner = substr(name, RSTART + 1, RLENGTH - 2)
        alt = substr(name, 1, RSTART - 1) "(" substr(inner, 1, index(inner, ", ") - 1) ")" substr(name, RSTART + RLENGTH)
        stem = lookup(enc(alt))
      }
      if (stem == "") next
      done[serial] = 1
      print cat "\t" serial "\t" repo "\t" path[stem] "\t" blob[stem]
    }
  ' "$WORK/$2.files" "$4"
}

CANDIDATES="$WORK/candidates.tsv"
{
  covers_candidates
  libretro_candidates screenshots libretro-ps1 Named_Snaps  "$MAP_FILE"
  libretro_candidates titles      libretro-ps1 Named_Titles "$MAP_FILE"
  # xlenore has no PSP cover set, so PSP covers come from libretro's boxarts
  libretro_candidates covers      libretro-psp Named_Boxarts "$PSP_MAP_FILE"
  libretro_candidates screenshots libretro-psp Named_Snaps   "$PSP_MAP_FILE"
  libretro_candidates titles      libretro-psp Named_Titles  "$PSP_MAP_FILE"
} > "$CANDIDATES"

# ── Plan: compare candidates with the manifest and existing outputs ────────
# keep   — output exists and was made from this exact upstream blob
# adopt  — output exists but predates the manifest; record its blob as-is
# update — output exists but upstream has a different blob now
# fetch  — no output yet (or --force)
# broken — no output, and this exact upstream blob failed to convert before
#          (upstream has some truncated and empty PNGs); retried once the
#          blob changes, or with --force
EXISTING="$WORK/existing.txt"
BROKEN="$CACHE/broken.tsv"
(cd "$ROOT" && find covers screenshots titles -name '*.jpg' 2>/dev/null) > "$EXISTING"
[[ -f "$MANIFEST" ]] || : > "$MANIFEST"
[[ -f "$BROKEN" ]] || : > "$BROKEN"

PLAN="$WORK/plan.tsv"
awk -F'\t' -v force="$FORCE" '
  FILENAME == ARGV[1] { made[$1 "\t" $2] = $5; next }
  FILENAME == ARGV[2] {
    n = split($0, p, "/"); s = p[n]; sub(/\.jpg$/, "", s)
    have[p[1] "\t" s] = 1; next
  }
  FILENAME == ARGV[3] { bad[$1 "\t" $2] = $4; next }
  {
    k = $1 "\t" $2
    if (k in seen) next
    seen[k] = 1
    if (force != "true" && !(k in have) && bad[k] == $5) a = "broken"
    else if (force == "true" || !(k in have)) a = "fetch"
    else if (!(k in made)) a = "adopt"
    else if (made[k] == $5) a = "keep"
    else a = "update"
    print a "\t" $0
  }
' "$MANIFEST" "$EXISTING" "$BROKEN" "$CANDIDATES" > "$PLAN"

# ── Fetch and convert ──────────────────────────────────────────────────────
TODO="$WORK/todo.tsv"
DONE="$WORK/done.tsv"
FAILED="$WORK/failed.tsv"
awk -F'\t' '$1 == "fetch" || $1 == "update"' "$PLAN" > "$TODO"
: > "$DONE"
: > "$FAILED"
todo_count=$(wc -l < "$TODO" | tr -d ' ')

echo ""
echo "=== Converting $todo_count new or changed images ==="
if [[ "$DRY_RUN" == true ]]; then
  awk -F'\t' '{ print "  " toupper($1) ": " $4 ":" $5 " → " $2 "/" $3 }' "$TODO"
elif [[ "$todo_count" -gt 0 ]]; then
  for repo in $REPOS; do
    awk -F'\t' -v r="$repo" '$4 == r { print $6 }' "$TODO" | sort -u > "$WORK/$repo.oids"
    if [[ -s "$WORK/$repo.oids" ]]; then
      echo "Fetching $(wc -l < "$WORK/$repo.oids" | tr -d ' ') images from $repo ..."
      fetch_blobs "$GIT_CACHE/$repo" "$WORK/$repo.oids"
    fi
  done

  i=0
  while IFS=$'\t' read -r action category serial repo path blob; do
    ((i++)) || true
    printf "\r\033[K  [%d/%d] %s/%s" "$i" "$todo_count" "$category" "$serial"
    dest="$(serial_dest_path "$category" "$serial")"
    tmp="$dest.tmp"
    if [[ "$path" == *.jpg ]]; then
      ok=true
      git -C "$GIT_CACHE/$repo" cat-file blob "$blob" > "$tmp" || ok=false
    else
      ok=true
      git -C "$GIT_CACHE/$repo" cat-file blob "$blob" \
        | $CONVERT - -quality 85 "jpg:$tmp" 2>/dev/null || ok=false
    fi
    if [[ "$ok" == true ]]; then
      mv "$tmp" "$dest"
      printf '%s\t%s\t%s\t%s\t%s\n' "$category" "$serial" "$repo" "$path" "$blob" >> "$DONE"
    else
      rm -f "$tmp"
      echo ""
      echo "  WARN: failed to convert $repo:$path"
      printf '%s\t%s\t%s\t%s\n' "$category" "$serial" "$repo" "$blob" >> "$FAILED"
    fi
  done < "$TODO"
  echo ""

  # Fetched images are no longer needed; the next run re-clones in seconds
  for repo in $REPOS; do
    if [[ -s "$WORK/$repo.oids" ]]; then rm -rf "${GIT_CACHE:?}/$repo"; fi
  done
fi

# ── Orphans ─────────────────────────────────────────────────────────────────
# An orphan is an output no upstream file matches any more, usually because
# the game was renamed in the DAT or upstream. Its image is often still
# right and consumers may link to it, so orphans are only listed unless
# --prune is passed. Single-serial runs match too few serials to tell.
ORPHANS="$WORK/orphans.txt"
: > "$ORPHANS"
if [[ -z "$SERIAL_FILTER" ]]; then
  awk -F'\t' '
    FILENAME == ARGV[1] { matched[$1 "\t" $2] = 1; next }
    {
      n = split($0, p, "/"); s = p[n]; sub(/\.jpg$/, "", s)
      if (!((p[1] "\t" s) in matched)) print
    }
  ' "$CANDIDATES" "$EXISTING" > "$ORPHANS"
  if [[ "$PRUNE" == true ]] && [[ "$DRY_RUN" == false ]]; then
    while IFS= read -r f; do rm -f "$ROOT/$f"; done < "$ORPHANS"
    (cd "$ROOT" && find covers screenshots titles -type d -empty -delete)
  fi
fi

# ── Write the manifest ─────────────────────────────────────────────────────
# Entries for this run's keep/adopt/converted outputs replace older ones;
# older entries stay for outputs this run did not touch (failed updates,
# serials outside --serial) as long as the output still exists.
if [[ "$DRY_RUN" == false ]]; then
  (cd "$ROOT" && find covers screenshots titles -name '*.jpg') > "$EXISTING"
  {
    awk -F'\t' -v OFS='\t' '$1 == "keep" || $1 == "adopt" { print $2, $3, $4, $5, $6 }' "$PLAN"
    cat "$DONE"
  } > "$WORK/current.tsv"
  awk -F'\t' '
    FILENAME == ARGV[1] { print; cur[$1 "\t" $2] = 1; next }
    FILENAME == ARGV[2] {
      n = split($0, p, "/"); s = p[n]; sub(/\.jpg$/, "", s)
      have[p[1] "\t" s] = 1; next
    }
    !(($1 "\t" $2) in cur) && (($1 "\t" $2) in have)
  ' "$WORK/current.tsv" "$EXISTING" "$MANIFEST" \
    | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"

  {
    awk -F'\t' -v OFS='\t' '$1 == "broken" { print $2, $3, $4, $6 }' "$PLAN"
    cat "$FAILED"
  } > "$BROKEN"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
awk -F'\t' '
  function sys(repo) { return repo == "libretro-psp" ? "PSP" : "PS1" }
  FILENAME == ARGV[1] { failed[$1 "\t" $2] = 1; next }
  {
    k = sys($4) " " $2
    keys[k] = 1
    a = $1
    if ((a == "fetch" || a == "update") && (($2 "\t" $3) in failed)) a = "failed"
    if (a == "broken") a = "failed"
    count[k, a]++
  }
  END {
    printf "  %-16s %7s %7s %7s %7s %7s\n", "", "keep", "adopt", "update", "new", "failed"
    fflush()
    for (k in keys)
      printf "  %-16s %7d %7d %7d %7d %7d\n", k, count[k, "keep"], count[k, "adopt"], \
        count[k, "update"], count[k, "fetch"], count[k, "failed"] | "sort"
  }
' "$FAILED" "$PLAN"
orphan_count=$(wc -l < "$ORPHANS" | tr -d ' ')
if [[ "$orphan_count" -gt 0 ]]; then
  if [[ "$PRUNE" == true ]]; then
    echo "Orphans: $orphan_count $([[ "$DRY_RUN" == true ]] && echo "would be " || true)deleted (list in $ORPHANS)"
  else
    echo "Orphans: $orphan_count outputs no upstream file matches (list in $ORPHANS; --prune deletes them)"
  fi
fi
echo "Cache: $(du -sh "$CACHE" | cut -f1)"
[[ "$DRY_RUN" == true ]] && echo "(dry-run — no files were written)"
echo "Done."
