# psx-artwork

PS1 game artwork served by serial number via `raw.githubusercontent.com`. A single CORS-friendly source for front covers, screenshots, and title screens — all keyed by hyphenated serial (e.g. `SLUS-00896`).

## Image Types

| Directory       | Content              | Source                     |
|-----------------|----------------------|----------------------------|
| `covers/`       | Front box art        | xlenore/psx-covers         |
| `screenshots/`  | Gameplay screenshots | libretro-thumbnails        |
| `titles/`       | Title screen captures| libretro-thumbnails        |

## URL Pattern

```
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/covers/{SERIAL}.jpg
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/screenshots/{SERIAL}.jpg
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/titles/{SERIAL}.jpg
```

Example:
```
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/covers/SLUS-00896.jpg
```

## Building

Prerequisites: `git`, `curl`, `ImageMagick`

```bash
./scripts/sync.sh          # fetch and convert artwork
./scripts/sync.sh --force  # re-convert even if files exist
```

The script clones upstream repos to `.cache/`, parses the redump DAT for serial-to-name mapping, copies covers, and converts libretro-thumbnails PNGs to JPEG.

## Credits

- **[xlenore/psx-covers](https://github.com/xlenore/psx-covers)** — PS1 cover artwork
- **[libretro-thumbnails/Sony - PlayStation](https://github.com/libretro-thumbnails/Sony_-_PlayStation)** — Screenshots and title screens
- **[libretro/libretro-database](https://github.com/libretro/libretro-database)** — Serial → game name mapping (redump DAT)
