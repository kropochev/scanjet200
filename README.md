# scanjet200

A macOS app and CLI for the **HP Scanjet 200** (Genesys GL848+). HP never shipped a driver for modern macOS; this is an unofficial implementation reconstructed from USB captures of the Windows driver.

The GUI is **Scanjet 200** (Image Capture–style). The command-line tool is `scanjet`.

USB ID: `03f0:1c05`. Optical resolution 2400 dpi, 48-bit CIS, A4 flatbed (~218 × 297 mm).

## System requirements

**Scanner**

- HP Scanjet 200 only (`03f0:1c05`). Other Genesys / Scanjet models are not supported.
- USB connection. Access is exclusive: close Image Capture, HP software, and other copies of this app before scanning.
- On first use macOS may ask for USB permission. Grant it, or scans will fail to open the device.

**Mac**

- macOS 13 Ventura or later on Apple Silicon.
- Enough free disk for the pass: a 2400 dpi A4 page is about 3.5 GB of raw scratch plus the output file (about 1.7 GB as uncompressed TIFF). 300 dpi is a few tens of megabytes.
- HEIC and JPEG 2000 depend on ImageIO on this Mac; if the codec is missing, the app reports an error instead of writing another format under that extension.

**To build**

- Xcode 15 or later (Swift 5.9+, macOS 13 SDK). Command Line Tools are enough for `swift build` if that SDK is installed.
- Git, to fetch the `Vendor/libusb` submodule. Homebrew is not required.

The packaged `.app` is unsigned. If Gatekeeper blocks it, open it from Finder (right-click → Open) after a local release build.

## Build

[libusb](https://github.com/libusb/libusb) is a git submodule (`Vendor/libusb`, branch `master`, version 1.0.30) and is compiled into the binary.

```bash
git submodule update --init --recursive
swift build -c release
./scripts/bundle-app.sh
./scripts/package-dmg.sh
```

Clone with `--recurse-submodules` so `Vendor/libusb` is populated.

The version in `VERSION` is compiled into both the GUI and `scanjet`. After changing it, run `./scripts/embed-version.sh` before building. A GitHub tag `v1.0.0` must match `VERSION`; the Build workflow then attaches `Scanjet-200-1.0.0-arm64.dmg` to a GitHub Release.

- GUI: `Scanjet 200.app` (created by `scripts/bundle-app.sh`)
- Disk image: `Scanjet-200-<version>.dmg` (app plus an Applications shortcut)
- CLI: inside the app at `Scanjet 200.app/Contents/MacOS/scanjet`, or `.build/release/scanjet`

```bash
"Scanjet 200.app/Contents/MacOS/scanjet" list
"Scanjet 200.app/Contents/MacOS/scanjet" scan -o ~/Desktop/page.tiff
```

Scans from the window still run in-process (live preview, Cancel, Custom Size).

## Tests

```bash
swift test
```

Parser, geometry, export, image correction, live preview, and `scanjet` process tests always run. Live USB tests skip unless the scanner is plugged in.

```bash
SCANJET_HARDWARE=1 swift test --filter HardwareTests   # fail if the scanner is missing
```

Hardware scans are 75 dpi and ~30 mm high (~10 s each). They do not run `calibrate` (that would overwrite shading profiles). Override the binary with `SCANJET_BIN=/path/to/scanjet`.

## GUI (Scanjet 200)

Two-column window: scan bed on the left, settings on the right. **Hide Details** collapses the settings column.

**Overview** is always a 75 dpi pass of the whole glass (~13 s), even if Custom Size is on. Lines appear on the bed as the carriage moves: each sample is shading-corrected (if a profile exists for that pass), then encoded with the same sRGB / gamma curve as the saved file. **Scan** uses the current Kind, Colours, Resolution, region, and Image Correction; the glass shows the same calibrated, tone-mapped stream while the pass runs. After Scan, a downsampled preview stays on the bed — the window does not load the full TIFF or PDF.

**Use Custom Size** and drag on the glass to set the scan rectangle. With the toggle off, the overlay is A4 or US Letter and cannot be dragged. **Orientation** rotates the saved file to match how the page sits on the glass.

**Cancel** (Escape) stops capture or decode, parks the carriage, and does not keep a partial file.

**Image Correction** is GUI-only. **None** leaves the scan as captured (after calibration and sRGB). **Manual** adds Brightness, Tint, Temperature, and Saturation; the glass updates while you drag, including during Overview and Scan. **Restore Defaults** centres the sliders. Scan writes that look into the file. The CLI never applies these sliders.

**Combine** appends pages into one PDF or multi-page TIFF when the checkbox is on and the file already exists. The CLI does the same with `--combine`.

**Calibrate** is in the menu (Scanjet 200 → Calibrate): 300 / 600 / 1200 / 2400 dpi, disabled when the scanner is unplugged. If this Mac has no shading files yet, a banner and the Calibration Assistant offer a first-run white-sheet setup. Help is ⌘?.

## CLI usage

```bash
scanjet --version                     # same version as the GUI About window
scanjet list                          # find the scanner
scanjet calibrate --dpi 300           # once per hardware mode: white A4 reference
scanjet scan -o page.tiff             # A4 colour TIFF at 300 dpi
scanjet scan --dpi 1200 -o page.tiff  # same at 1200 dpi
scanjet scan --kind gray --size letter --orientation 90 -o page.png
scanjet scan --format pdf --combine --name Report
scanjet scan --colours billions -o page.tiff
scanjet scan --kind text --format pdf -o ocr.pdf
scanjet scan --height 120 -o strip.tiff   # top 120 mm of the selected paper size
scanjet scan --gamma 1.8 --no-shading -o linear.tiff
```

`scan` uses the same pipeline as the GUI: Kind, Colours, Resolution, Size (A4 / US Letter), Orientation, name, format, and Combine. **Use Custom Size** and **Image Correction** stay GUI-only.

| flag | GUI control | values |
|------|-------------|--------|
| `--kind` | Kind | `colour` (default), `gray`, `text` |
| `--mode` | Kind | `color` \| `gray` (alias for `--kind`) |
| `--colours` | Colours | `millions` (8-bit, default), `billions` (16-bit, TIFF and PNG only) |
| `--dpi` | Resolution | 75 100 150 200 300 600 1200 2400 |
| `--size` | Size | `a4` (default), `letter` |
| `--orientation` | Orientation | `0` `90` `180` `270` |
| `-o` / `--name` / `--format` | Scan To, Name, Format | jpeg heic tiff png jp2 gif bmp pdf |
| `--combine` | Combine | append to an existing PDF or multi-page TIFF |
| `--height` | (CLI) | millimetres from the top of the selected paper size |
| `--gamma` | (CLI) | tone curve; omit for sRGB |
| `--shading` | Calibrate | path to a shading file (default in Application Support) |
| `--no-shading` | (CLI) | skip column calibration |
| `--raw` | (CLI) | keep the 16-bit CIS dump next to the result |
| `--feed` | (CLI) | FEEDL steps from park (default from the HP log) |

`-o` is a file (overwritten) or an existing folder. Without `-o`, the file is `scan.tiff` in the current directory; a number is added if that name is taken, unless `--combine` is on. `--format` must match the `-o` extension when both are set.

`--raw` keeps the 16-bit CIS dump next to the result.

### Resolutions

The scanner has four hardware passes; everything else is integer box-filter downsampling, matching the Windows driver (75 and 150 dpi are also captured at 300 dpi).

| `--dpi` | pass | A4 size        | time   |
|---------|------|----------------|--------|
| 75      | 300  | 621×877        | 13 s   |
| 100     | 300  | 828×1169       | 13 s   |
| 150     | 300  | 1243×1754      | 13 s   |
| 200     | 600  | 1656×2338      | 47 s   |
| 300     | 300  | 2486×3508      | 13 s   |
| 600     | 600  | 4970×7016      | 47 s   |
| 1200    | 1200 | 9942×14032     | 3 min  |
| 2400    | 2400 | 19882×28056    | 12 min |

The sensor sees about 218 mm; A4 is cropped to 210 mm (US Letter to 215.9 mm), matching the GUI. Vertical and horizontal scale were checked against a reference scan; mismatch is under 0.5%.

A 2400 dpi page is 3.5 GB of raw data and 1.7 GB of TIFF, so capture and decode stream through a scratch file rather than RAM.

### Calibration

CIS segments differ in sensitivity by about 8%, which shows up as vertical bands and a blue cast. `scanjet calibrate` scans a clean white A4 sheet, averages each column per channel, and stores the reference at `~/Library/Application Support/scanjet/shading-<dpi>.bin`. `scan` and the GUI load it automatically. Use a flat, unmarked sheet — creases will bake into the profile. A cream sheet will push every later scan toward blue.

Each hardware pass has its own sensor width, so calibrate all four you use. 300 dpi also covers 75, 100, and 150 dpi; 600 dpi also covers 200 dpi. A profile belongs to this scanner and this Mac.

```bash
for d in 300 600 1200 2400; do scanjet calibrate --dpi $d; done
```

Column noise is more visible at higher dpi: without calibration, 1200 and 2400 dpi show a one-pixel vertical stripe. After calibration a white field has ~0.8% column spread and R:G:B ≈ 1.000 : 1.000 : 0.999.

Disable correction with `--no-shading`. Use another file with `--shading PATH`.

### Tone and colour

The ASIC gamma table is a straight line, so CIS data is linear reflectance. Displays expect sRGB, so 8-bit output is encoded with the standard sRGB transfer function. Live Overview/Scan on the glass uses the same curve (and the same shading) as the file, not a raw high-byte preview.

The black point is fixed at 10% of white — the measured sensor dark floor (raw minimum on a densely printed page: 4556 with white at 43425). Adapting it to the frame would crush midtones on a light original.

White balance comes from calibration, which maps all three channels to one level.

`--gamma 2.4` is brighter, `--gamma 1.8` is punchier, `--gamma 1` is linear. Kind **Text** is high-contrast (fixed threshold), not OCR.

### Frame position

The frame starts after `FEEDL` steps from the park position. Defaults come from the HP log for that pass (543 at 300 dpi, 489 at 600, 552 at 1200 and 2400). All four passes start at the same place on the glass. If the top of the page is missing or the bottom has a blank strip, the carriage did not start at home — only change `--feed` after confirming parking.

## How it works

The protocol was reverse-engineered from USBPcap captures of the Windows driver:

- **Scan status lives in the high register bank.** Read `0x100` (`wValue = 0x8E | 0x100`), not `0x00` — `0x00` is the chip id `0x95` and never changes. `0x100` goes `0xb2` (empty buffer) → `0x36` → `0x33` (frame in DRAM). The valid-word counter is four bytes at `0x102`.
- **The frame is read in chunks.** Chunk size depends on the pass: 196 080 bytes (38 lines × 2580 samples) at 300 dpi, about a megabyte otherwise. A full A4 at 300 dpi is 10 524 CIS lines, i.e. 3508 RGB rows × 3 colour lines; each higher pass doubles both line count and samples.
- **Samples are 16-bit big-endian.** The CIS scans right to left, so each line is mirrored on decode.
- **Wait for the carriage to home.** There is no separate “go home” command: after `0x0a=0x40` / `0x01=0xc0` the pass drives back, which takes up to 15 s. Ready means `0x101` has bit 0x08 (home sensor) set **and** bit 0x01 (motor) clear. Checking only “motor stopped” is wrong: right after the command the motor has not started yet, and the next scan begins below the glass edge. Writing `0x0f=0x00` and clearing bit 0 of `0x01` while idle clears the home flag, so those writes happen only when a capture is actually running (`0x100` = `0x33`). A stuck carriage is recovered with a short dummy pass.

ASIC init is replayed exactly as the HP driver does it. Sequences extracted from the Windows logs live in `Sources/ScanjetCore/hp_<dpi>.{txt,bin}`; `HPProgram.runInit` runs the matching one up to `0x0F=0xFF`, patching LINCNT and FEEDL. After that the app polls status and reads DRAM itself.

## License

scanjet200 is MIT. Bundled [libusb](https://github.com/libusb/libusb) is LGPL-2.1-or-later (`Vendor/libusb/COPYING`). HP, Scanjet, and Genesys are trademarks of their owners. This project is not affiliated with HP.
