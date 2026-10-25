# psx-artwork

PS1 and PSP game artwork served by serial number via `raw.githubusercontent.com`. A single CORS-friendly source for front covers, screenshots, and title screens — all keyed by hyphenated serial (e.g. `SLUS-00896`, `ULUS-10277`).

Both systems share one tree. PS1 and PSP serials never collide, so a lookup by serial works the same for either.

## Image Types

| Directory       | Content              | PS1 source                 | PSP source                 |
|-----------------|----------------------|----------------------------|----------------------------|
| `covers/`       | Front box art        | xlenore/psx-covers         | libretro-thumbnails        |
| `screenshots/`  | Gameplay screenshots | libretro-thumbnails        | libretro-thumbnails        |
| `titles/`       | Title screen captures| libretro-thumbnails        | libretro-thumbnails        |

## URL Pattern

Images are nested by serial prefix and first 3 digits to keep directories browsable on GitHub:

```
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/{category}/{PREFIX}/{DIGITS}/{SERIAL}.jpg
```

Where:
- `PREFIX` = letters before the hyphen (e.g. `SLUS`)
- `DIGITS` = first 3 digits after the hyphen (e.g. `008` from `SLUS-00896`)
- `SERIAL` = full serial (e.g. `SLUS-00896`)

Example:
```
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/covers/SLUS/008/SLUS-00896.jpg
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/screenshots/SLUS/008/SLUS-00896.jpg
https://raw.githubusercontent.com/{OWNER}/psx-artwork/main/titles/SLUS/008/SLUS-00896.jpg
```

Building a URL from a serial:
```js
const [prefix, num] = serial.split('-');
const digits = num.substring(0, 3);
const url = `https://raw.githubusercontent.com/${owner}/psx-artwork/main/${category}/${prefix}/${digits}/${serial}.jpg`;
```

## Building

Prerequisites: `git`, `curl`, `ImageMagick`

```bash
./scripts/sync.sh          # fetch and convert artwork
./scripts/sync.sh --force  # re-convert even if files exist
```

The script clones upstream repos to `.cache/`, parses the PS1 and PSP redump DATs for serial-to-name mapping, copies PS1 covers, and converts libretro-thumbnails PNGs to JPEG. PSP serials outside the usual `ABCD-12345` shape (promo and dev discs) are skipped.

## Credits

- **[xlenore/psx-covers](https://github.com/xlenore/psx-covers)** — PS1 cover artwork (sourced from psxdatacenter.com / duckstation.org)
- **[libretro-thumbnails/Sony - PlayStation](https://github.com/libretro-thumbnails/Sony_-_PlayStation)** — PS1 screenshots and title screens
- **[libretro-thumbnails/Sony - PlayStation Portable](https://github.com/libretro-thumbnails/Sony_-_PlayStation_Portable)** — PSP covers, screenshots and title screens
- **[libretro/libretro-database](https://github.com/libretro/libretro-database)** — Serial → game name mapping (redump DATs, CC BY-SA 4.0)

## Disclaimer

All game artwork (covers, screenshots, title screens) is the property of the respective game publishers and developers. This repository aggregates and re-keys existing publicly available artwork for personal/hobbyist use. No ownership is claimed. If you are a rights holder and want content removed, please open an issue.
