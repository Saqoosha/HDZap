#!/usr/bin/env python3
"""Crop iOS Settings screenshots into per-section pieces.

iOS Settings groups rows into white rounded-rect "cards" separated by a
band of background gray. We detect those gray bands by looking for rows
where ~all pixels match the background color, then group adjacent
non-gray rows into one card per section. Crop boundaries include the
section header (UPPERCASE text, just above the white card) so each
output PNG is self-contained.
"""
import sys
from pathlib import Path
from PIL import Image
import numpy as np


# Settings background gray, roughly. Both en and ja use the same.
# Sampled from a known background pixel. Allow ±8 per channel.
BG_RGB = (242, 242, 247)
TOL = 12

# Crops will be downscaled so the longest side fits this many px. Picked
# for retina sharpness: manuals embed images at `width="360"` CSS px, so
# 1440 source pixels = 4× of the displayed width, which renders crisp on
# both 2× and 3× displays (iPhone 16 Plus + Pro Max are both 3×).
# Going below 1080 would visibly soften on 3× devices.
TARGET_LONG_EDGE = 1440

# Pixels of buffer added above and below the detected section band, AND
# the height of the fade-to-white gradient applied to that buffer. The
# two are paired so the gradient lives entirely in the buffer rows
# (i.e. outside the section content) — the section header + card body
# stay fully visible in the output.
FADE_PX = 80


def is_bg_row(row_rgb: np.ndarray) -> bool:
    """Return True if (almost) every pixel in this row matches BG_RGB."""
    diff = np.abs(row_rgb.astype(int) - np.array(BG_RGB))
    matching = (diff <= TOL).all(axis=-1)
    # Allow ≤2% non-bg pixels (e.g. a separator line edge) and still call it bg.
    return matching.mean() > 0.98


def find_card_bands(img: Image.Image, top_skip_px: int, bottom_skip_px: int):
    """Return [(start_y, end_y), ...] for each logical section.

    A "logical section" here is the section-header text block (e.g.
    `FORMAT`) plus its main white card glued together — iOS visually
    treats them as one unit but they have a small (~140 px) gutter
    between them, so naïve "contiguous non-bg" detection splits them.
    We post-process by merging adjacent non-bg runs whose gap is
    smaller than `MAX_HEADER_GAP_PX`.

    Status bar and home indicator are clipped via the skip args because
    they're not part of the scrollable list and would otherwise be
    grouped with whatever sits below them.
    """
    arr = np.array(img.convert("RGB"))
    h = arr.shape[0]
    raw = []
    in_card = False
    start = 0
    for y in range(top_skip_px, h - bottom_skip_px):
        row = arr[y]
        is_bg = is_bg_row(row)
        if not is_bg and not in_card:
            start = y
            in_card = True
        elif is_bg and in_card:
            raw.append((start, y))
            in_card = False
    if in_card:
        raw.append((start, h - bottom_skip_px))
    # Drop tiny non-bg blips (sub-pixel anti-aliasing, < 8 px tall)
    raw = [(a, b) for a, b in raw if b - a >= 8]
    # Merge intra-section gaps in two passes:
    # 1. Small gaps (<50 px) — covers tight intra-section gutters
    #    (card body → footer text on iOS 26.5, header → body when
    #    the header sits close to the card).
    # 2. Orphan-header rescue — a "card" shorter than 110 px is almost
    #    certainly the section-header text on its own. Force-merge it
    #    into the next card if the gap is at most 250 px. Covers both
    #    the JA layout (wider header → wider gap) AND the iOS 26.5
    #    layout (inter-section gap dropped to ~65-100 px, so the
    #    threshold-1 pass can't grab the header).
    #
    # Threshold tuning history:
    #  - iOS 26.4: 95 px worked because inter-section gaps were 100+.
    #  - iOS 26.5: inter-section gap dropped to ~65-100 px, so a 95
    #    threshold over-merged sections. Lowered to 50 + relied on the
    #    orphan-rescue pass to re-attach the now-split header text.
    MAX_INTRA_GAP_PX = 50
    MAX_ORPHAN_GAP_PX = 250
    ORPHAN_MAX_HEIGHT_PX = 110
    merged: list[tuple[int, int]] = []
    for a, b in raw:
        if merged and a - merged[-1][1] <= MAX_INTRA_GAP_PX:
            merged[-1] = (merged[-1][0], b)
        else:
            merged.append((a, b))
    rescued: list[tuple[int, int]] = []
    i = 0
    while i < len(merged):
        a, b = merged[i]
        if (i + 1 < len(merged)
                and b - a <= ORPHAN_MAX_HEIGHT_PX
                and merged[i + 1][0] - b <= MAX_ORPHAN_GAP_PX):
            rescued.append((a, merged[i + 1][1]))
            i += 2
        else:
            rescued.append((a, b))
            i += 1
    # Drop merged sections that are still tiny (< 80 px) — usually leftover
    # toolbar artifacts that didn't merge into anything.
    return [(a, b) for a, b in rescued if b - a >= 80]


def crop_with_header(img: Image.Image, band: tuple,
                     fade_buffer_px: int = FADE_PX):
    """Crop a logical section plus `fade_buffer_px` of buffer rows
    above and below.

    The buffer rows exist for two reasons:
    1. They're where `apply_edge_fade` paints the fade-to-white
       gradient, so the gradient lives in space that is NOT part of
       the section content — the section card and its header stay
       fully visible in the output.
    2. They provide a hint of context (a faded glimpse of the
       previous footer text or the next section header) so the
       reader can mentally place the crop inside the longer scroll.

    `find_card_bands` already merges the section's header text +
    body + optional footer into one band; everything outside that
    band is by definition "context for the next/previous section"
    and is safe to fade.
    """
    start_y, end_y = band
    start_y = max(0, start_y - fade_buffer_px)
    end_y = min(img.height, end_y + fade_buffer_px)
    return img.crop((0, start_y, img.width, end_y))


def downscale(img: Image.Image, target: int = TARGET_LONG_EDGE) -> Image.Image:
    """Scale so the longer side ≤ target, preserving aspect."""
    w, h = img.size
    long_side = max(w, h)
    if long_side <= target:
        return img
    scale = target / long_side
    return img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)


def apply_edge_fade(img: Image.Image,
                    fade_px: int = FADE_PX,
                    bg_rgb: tuple = (255, 255, 255)) -> Image.Image:
    """Fade the top-and-bottom `fade_px` rows to white so the cropped
    PNG blends into the surrounding white manual page.

    `crop_with_header` deliberately extends its bounds beyond the
    section by exactly `fade_px` (the `FADE_PX` constant), so the
    rows touched by this fade are NOT the section content — they're
    the buffer rows containing whatever the next/previous section
    looks like. The section header + card body live entirely in the
    middle rows that this fade doesn't touch.

    Implementation: build a vertical alpha gradient for the top and
    bottom `fade_px` rows (0 = full background, 255 = original pixel),
    then composite the original over a solid white backdrop using
    that alpha. Skips the fade entirely when the image is too short
    (<3·fade_px) so a small card doesn't get washed out — this
    matters mostly for very short standalone screens like the rename
    sub-view.
    """
    if fade_px <= 0:
        return img
    w, h = img.size
    if h < 3 * fade_px:
        return img
    rgba = img.convert("RGBA")
    alpha = Image.new("L", (w, h), 255)
    pixels = alpha.load()
    for y in range(fade_px):
        # Linear ramp: row 0 = 0 (fully transparent → background shows
        # through), row fade_px-1 = ~255 (original pixel).
        a = int(round((y / max(1, fade_px - 1)) * 255))
        for x in range(w):
            pixels[x, y] = a
        ay = h - 1 - y
        for x in range(w):
            pixels[x, ay] = a
    rgba.putalpha(alpha)
    backdrop = Image.new("RGB", (w, h), bg_rgb)
    backdrop.paste(rgba, (0, 0), rgba)
    return backdrop


def crop_file(src: Path, out_dir: Path, prefix: str,
              section_names: list[str],
              top_skip: int = 380, bottom_skip: int = 30):
    """Crop `src` into one PNG per detected card, labeled by `section_names`."""
    img = Image.open(src)
    bands = find_card_bands(img, top_skip, bottom_skip)
    print(f"  {src.name}: {len(bands)} cards detected at "
          f"{[f'{a}-{b}' for a, b in bands]}")
    if len(bands) != len(section_names):
        print(f"  WARN: expected {len(section_names)} sections "
              f"({section_names}), got {len(bands)}")
    for i, (band, name) in enumerate(zip(bands, section_names)):
        cropped = crop_with_header(img, band)
        # Apply the edge fade at native resolution so the gradient stays
        # smooth even after the LANCZOS downscale crunches the pixel grid.
        # The fade height matches the buffer height in `crop_with_header`,
        # so the gradient lives entirely in the buffer rows and never
        # overlaps the section content.
        cropped = apply_edge_fade(cropped)
        cropped = downscale(cropped)
        out = out_dir / f"{prefix}-{name}.png"
        cropped.save(out, optimize=True)
        print(f"    -> {out.name} ({cropped.size[0]}x{cropped.size[1]})")


def main():
    src_root = Path("/tmp/hdzap_settings_shots")
    out = Path("/tmp/hdzap_crops")
    out.mkdir(exist_ok=True)

    # Each entry: (src basename pattern, output prefix, ordered section names).
    # Section names mirror the iOS list-section headers, top-to-bottom.
    # `top_skip` overrides default 380 for views whose nav-bar/title is
    # narrower than the Settings sheet (modal vs. push presentation).
    jobs = [
        # Settings root (bridge ON, fake-connected) — sections:
        # FORMAT, DEVICE, APP, ABOUT
        ("settingsRoot-{}.png", "settings-root",
         ["format", "device", "app", "about"], 380),
        # Standalone mode (bridge OFF). DEBUG section hidden via ScreenshotMode.
        # FORMAT, DEVICE (just the Use-bridge toggle + footer hint), APP, ABOUT
        ("settingsRootStandalone-{}.png", "settings-standalone",
         ["format", "device", "app", "about"], 380),
        # Bridge ON but not yet connected — Use bridge ON, M5StickS3 row
        # reads "Not connected", Goggle pairing reads "—". Used by §5 to
        # show what a fresh user sees right after enabling the bridge.
        ("settingsRootBridgeOnUnconnected-{}.png", "settings-bridgeon",
         ["format", "device", "app", "about"], 380),
        # Settings root scrolled to the bottom so the ABOUT card is in
        # view. The default settingsRoot screenshot has About below the
        # viewport on iOS 26.5; this scrolled variant exists purely to
        # crop a usable ABOUT image. Detection sees Format (partially
        # cropped at top), Device, App, About.
        ("settingsRootAbout-{}.png", "settings-scrolled",
         ["format", "device", "app", "about"], 380),
        # Lap announcer (System engine) — ANNOUNCEMENT, VOICE
        ("audio-{}.png", "audio-system", ["announcement", "voice"], 380),
        # Lap announcer (Premium engine) — same two sections, premium content
        ("audioPremium-{}.png", "audio-premium", ["announcement", "voice"], 380),
        # Lap announcer with the countdown toggle ON so the 'Start at'
        # stepper is visible. Same two sections as the default audio
        # screen; we only consume the ANNOUNCEMENT crop downstream.
        ("audioCountdownOn-{}.png", "audio-countdown", ["announcement", "voice"], 380),
        # Connection sub-view — CONNECTED card, BLUETOOTH NAME (rename
        # drill-in row), OTHER DEVICES card with a seeded fake row, and
        # the SCAN button. Pushed via NavigationLink so the title sits
        # ~340 px from top.
        ("connection-{}.png", "connection",
         ["connected", "bluetooth-name", "other-devices", "scan"], 340),
        # Pairing sub-view — CURRENT UID, CONFIGURE (mode picker + form),
        # TX UID CAPTURE. Default route fills the Bind Phrase field with
        # a representative phrase so the configure crop shows the derived
        # UID line.
        ("pairing-{}.png", "pairing",
         ["current-uid", "configure", "tx-uid-capture"], 340),
        # Pairing with Manual UID mode pre-selected + a representative UID
        # typed in. Only `configure` is meaningfully different from the
        # default route (the other two cards stay identical); we still emit
        # all three to keep the per-section naming uniform.
        ("pairingManualUID-{}.png", "pairing-manual",
         ["current-uid", "configure", "tx-uid-capture"], 340),
        # Pairing with New Pairing mode pre-selected — the form collapses
        # to a single "Pair with new goggle" button.
        ("pairingNewPairing-{}.png", "pairing-new",
         ["current-uid", "configure", "tx-uid-capture"], 340),
        # Pairing screen with the green success banner pre-painted
        # (.success phase). Same 3 sections; the banner sits inside the
        # CONFIGURE card.
        ("pairingSuccess-{}.png", "pairing-success",
         ["current-uid", "configure", "tx-uid-capture"], 340),
        # Rename device sub-view — single BLUETOOTH NAME card.
        ("rename-{}.png", "rename", ["bluetooth-name"], 340),
        # OSD layout sub-view — PREVIEW, POSITION, ALIGNMENT, SHOW ROWS, BUTTONS
        # (Send Test OSD / Clear OSD, Reset layout). The buttons are below the
        # visible viewport so the bottom-most card may be clipped — that's OK
        # for documentation since the buttons are described in text.
        ("osdLayout-{}.png", "osd-layout",
         ["preview", "position", "alignment", "show-rows"], 340),
    ]

    for pattern, prefix, names, top_skip in jobs:
        for lang in ("en", "ja"):
            src = src_root / pattern.format(lang)
            if not src.exists():
                print(f"SKIP: {src} missing")
                continue
            print(f"{src.name}")
            crop_file(src, out, f"{prefix}-{lang}", names, top_skip=top_skip)

    print("\nGenerated files:")
    for f in sorted(out.glob("*.png")):
        print(f"  {f.name}")


if __name__ == "__main__":
    main()
