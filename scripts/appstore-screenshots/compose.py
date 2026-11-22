#!/usr/bin/env python3
"""Compose Scriber's App Store screenshots from raw simulator captures.

Inputs : docs/appstore/raw/0N-*.png   (1320 x 2868 captures from an iPhone 17 Pro Max simulator)
Outputs: docs/appstore/screenshots/zh-Hant/0N-*.png       6.9"  1320 x 2868
         docs/appstore/screenshots/zh-Hant-6.5/0N-*.png   6.5"  1284 x 2778
         docs/appstore/screenshots/preview.jpg            contact sheet of the 6.9" set

Every size is laid out from scratch (text, device frame and screen are placed for that canvas);
the raw capture is only ever scaled down. Requires Pillow and the PingFang TC system font.

    python3 scripts/appstore-screenshots/compose.py
"""
from __future__ import annotations

import glob
import io
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "docs/appstore/raw"
OUT = ROOT / "docs/appstore/screenshots"

# Brand palette (app icon / AccentColor #D97757).
TERRACOTTA = (0xD9, 0x77, 0x57)
INK = (0x1F, 0x1A, 0x17)  # near-black, warm
PAPER = (0xFA, 0xF6, 0xF0)  # warm off-white
DEVICE = (0x1B, 0x19, 0x17)
DEVICE_EDGE = (0x3B, 0x36, 0x32)

# Where the Dynamic Island sits in a 1320 px wide iPhone 17 Pro Max capture (measured).
ISLAND = (472, 42, 848, 152)


@dataclass
class Strike:
    """Callout for shot 2: the spoken transcript with the removed parts struck through, then
    the inserted text. Both strings come from the real pipeline (see README)."""
    spoken: list[tuple[str, bool]]  # (text, removed); "\n" forces a line break
    result: str
    # Vertical placement of the card, as a fraction of the screen height (top edge).
    screen_top: float = 0.135


@dataclass
class Shot:
    raw: str
    out: str
    headline: list[str]
    sub: str
    strike: Strike | None = None


SPOKEN = [
    ("嗯，", True), ("簡報我來準備，", False), ("呃，", True), ("週四前會先放到共用資料夾。\n", False),
    ("那個，", True), ("如果 API 文件還沒更新，", False), ("我", True), ("我順便整理一下。", False),
]
RESULT = "簡報我來準備，週四前會先放到共用資料夾。\n如果 API 文件還沒更新，我順便整理一下。"

SHOTS = [
    Shot("01-keyboard-recording.png", "01-dictate.png",
         ["按一下說話", "文字自己打好"],
         "在任何 App 切到 Scriber 鍵盤，再按一下就完成"),
    Shot("02-keyboard-result.png", "02-clean-text.png",
         ["說完，就是", "整理好的繁體中文"],
         "去掉嗯、呃、那個和口吃，全形標點、台灣用語",
         strike=Strike(SPOKEN, RESULT)),
    Shot("03-keyboard-translate.png", "03-translate.png",
         ["說中文", "直接變成英文、日文、韓文"],
         "長按翻譯鍵，在三個常用語言之間切換"),
    Shot("04-app-home.png", "04-time-saved.png",
         ["省下多少時間", "一看就知道"],
         "和用手機打字相比估算，已扣掉說話的時間"),
    Shot("05-app-settings.png", "05-own-api-key.png",
         ["用你自己的 API key", "沒有月費"],
         "聲音直接送到你選的服務，用量由服務商計費"),
]

SIZES = {
    "zh-Hant": (1320, 2868),
    "zh-Hant-6.5": (1284, 2778),
}

# ---------------------------------------------------------------------------------------------
# Fonts


def _pingfang_path() -> str:
    candidates = glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")
    candidates += glob.glob("/System/Library/Fonts/PingFang.ttc") + glob.glob("/Library/Fonts/PingFang.ttc")
    if not candidates:
        try:
            listed = subprocess.run(["fc-list", ":family=PingFang TC", "file"], capture_output=True, text=True).stdout
            candidates = [line.split(":")[0] for line in listed.splitlines() if line.strip()]
        except FileNotFoundError:
            pass
    if not candidates:
        raise SystemExit("PingFang TC not found (macOS system font).")
    return candidates[0]


_FONT_PATH = _pingfang_path()
_FACE_INDEX: dict[str, int] = {}


def font(style: str, size: float) -> ImageFont.FreeTypeFont:
    """PingFang TC in the given style (Regular, Medium, Semibold, Light)."""
    if style not in _FACE_INDEX:
        for index in range(64):
            try:
                face = ImageFont.truetype(_FONT_PATH, 20, index=index)
            except OSError:
                break
            if face.getname() == ("PingFang TC", style):
                _FACE_INDEX[style] = index
                break
        else:
            raise SystemExit(f"PingFang TC {style} not found in {_FONT_PATH}")
    return ImageFont.truetype(_FONT_PATH, round(size), index=_FACE_INDEX[style])


def text_width(text: str, f: ImageFont.FreeTypeFont) -> float:
    return f.getlength(text)


# ---------------------------------------------------------------------------------------------
# Drawing helpers


def rounded_mask(size: tuple[int, int], radius: float, scale: int = 4) -> Image.Image:
    """Anti-aliased rounded-rectangle mask (drawn large, then reduced)."""
    w, h = size
    big = Image.new("L", (w * scale, h * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * scale - 1, h * scale - 1), radius=radius * scale, fill=255)
    return big.resize((w, h), Image.LANCZOS)


def paste_rounded(canvas: Image.Image, color, box: tuple[int, int, int, int], radius: float) -> None:
    x0, y0, x1, y1 = box
    layer = Image.new("RGB", (x1 - x0, y1 - y0), color)
    canvas.paste(layer, (x0, y0), rounded_mask((x1 - x0, y1 - y0), radius))


def draw_centered(draw: ImageDraw.ImageDraw, text: str, f, cx: float, y: float, fill) -> None:
    draw.text((cx - text_width(text, f) / 2, y), text, font=f, fill=fill)


NO_LINE_START = set("，。、：；！？」』）,.!?")


def wrap_runs(runs: list[tuple[str, bool]], f, width: float) -> list[list[tuple[str, bool]]]:
    """Character wrap for CJK with simple kinsoku (no punctuation at a line start).
    Latin words are kept together."""
    tokens: list[tuple[str, bool]] = []
    for text, flag in runs:
        word = ""
        for ch in text:
            if ch.isascii() and ch.isalnum():
                word += ch
                continue
            if word:
                tokens.append((word, flag))
                word = ""
            tokens.append((ch, flag))
        if word:
            tokens.append((word, flag))
    lines: list[list[tuple[str, bool]]] = [[]]
    x = 0.0
    for tok, flag in tokens:
        if tok == "\n":
            lines.append([])
            x = 0.0
            continue
        w = text_width(tok, f)
        if x + w > width and lines[-1] and tok not in NO_LINE_START and tok != " ":
            lines.append([])
            x = 0.0
        if not lines[-1] and tok == " ":
            continue
        lines[-1].append((tok, flag))
        x += w
    return lines


# ---------------------------------------------------------------------------------------------
# Layout


@dataclass
class Layout:
    width: int
    height: int
    s: float = field(init=False)  # scale relative to the 1320 px design

    def __post_init__(self):
        self.s = self.width / 1320

    def px(self, v: float) -> int:
        return round(v * self.s)


def common_size(layout: Layout, style: str, design_size: float, lines: list[str]) -> float:
    """One size for the whole set: the design size, or smaller if a line would not fit
    between the side margins."""
    max_width = layout.width - 2 * layout.px(96)
    size = design_size * layout.s
    probe = font(style, 100)
    for line in lines:
        size = min(size, 100 * max_width / text_width(line, probe))
    return size


def text_sizes(layout: Layout) -> tuple[float, float]:
    head = common_size(layout, "Semibold", 100, [line for shot in SHOTS for line in shot.headline])
    sub = common_size(layout, "Regular", 52, [shot.sub for shot in SHOTS])
    return head, sub


def compose(shot: Shot, layout: Layout, sizes: tuple[float, float]) -> Image.Image:
    W, H = layout.width, layout.height
    px = layout.px
    canvas = Image.new("RGB", (W, H), TERRACOTTA)
    draw = ImageDraw.Draw(canvas)

    # Headline + subhead
    size, sub_size = sizes
    head_font = font("Semibold", size)
    sub_font = font("Regular", sub_size)
    y = px(150)
    line_gap = size * 1.24
    for line in shot.headline:
        draw_centered(draw, line, head_font, W / 2, y, INK)
        y += line_gap
    y += px(34)
    draw_centered(draw, shot.sub, sub_font, W / 2, y, mix(INK, TERRACOTTA, 0.82))
    y += sub_size * 1.35

    # Device: everything below the text, full height visible.
    raw = Image.open(RAW / shot.raw).convert("RGB")
    bezel = px(26)
    top = round(y + px(70))
    bottom_margin = px(112)
    screen_h = H - top - bottom_margin - 2 * bezel
    screen_w = round(screen_h * raw.width / raw.height)
    screen_h = round(screen_w * raw.height / raw.width)
    dev_w, dev_h = screen_w + 2 * bezel, screen_h + 2 * bezel
    dev_x = (W - dev_w) // 2
    dev_y = top
    screen_radius = screen_w * 0.141
    paste_rounded(canvas, DEVICE_EDGE, (dev_x, dev_y, dev_x + dev_w, dev_y + dev_h), screen_radius + bezel)
    edge = max(2, px(4))
    paste_rounded(canvas, DEVICE, (dev_x + edge, dev_y + edge, dev_x + dev_w - edge, dev_y + dev_h - edge),
                  screen_radius + bezel - edge)

    scale = screen_w / raw.width
    assert scale <= 1.0, "never upscale the capture"
    screen = raw.resize((screen_w, screen_h), Image.LANCZOS)
    # Dynamic Island, drawn the same on every shot (the simulator captures it inconsistently).
    island = [round(v * scale) for v in ISLAND]
    ImageDraw.Draw(screen).rounded_rectangle(island, radius=(island[3] - island[1]) / 2, fill=(0, 0, 0))
    sx, sy = dev_x + bezel, dev_y + bezel
    canvas.paste(screen, (sx, sy), rounded_mask((screen_w, screen_h), screen_radius))

    if shot.strike:
        draw_strike_card(canvas, layout, shot.strike, (sx, sy, screen_w, screen_h))
    return canvas


def mix(a, b, t: float):
    """t of a, (1 - t) of b."""
    return tuple(round(a[i] * t + b[i] * (1 - t)) for i in range(3))


def draw_strike_card(canvas: Image.Image, layout: Layout, strike: Strike, screen) -> None:
    px = layout.px
    sx, sy, sw, sh = screen
    card_x0 = px(96)
    card_x1 = layout.width - px(96)
    pad = px(52)
    inner = card_x1 - card_x0 - 2 * pad

    label_font = font("Medium", 38 * layout.s)
    # Largest size (up to 46) at which every forced line fits on one line.
    body_size = 46 * layout.s
    probe = font("Regular", 100)
    for runs in (strike.spoken, [(strike.result, False)]):
        for line in "".join(t for t, _ in runs).split("\n"):
            body_size = min(body_size, 100 * inner / text_width(line, probe))
    body_font = font("Regular", body_size)
    line_h = body_size * 1.52
    spoken_lines = wrap_runs(strike.spoken, body_font, inner)
    result_lines = wrap_runs([(strike.result, False)], body_font, inner)
    label_h = 38 * layout.s * 1.6
    gap = px(34)
    height = pad + label_h + len(spoken_lines) * line_h + gap + px(2) + gap + label_h + len(result_lines) * line_h + pad - px(12)

    card_y0 = round(sy + sh * strike.screen_top)
    box = (card_x0, card_y0, card_x1, round(card_y0 + height))
    paste_rounded(canvas, INK, box, px(44))
    draw = ImageDraw.Draw(canvas)

    muted = mix(PAPER, INK, 0.55)
    struck = (0xEE, 0x93, 0x74)  # lighter terracotta: readable on the dark card
    x0 = card_x0 + pad
    y = card_y0 + pad
    draw.text((x0, y), "你說的", font=label_font, fill=muted)
    y += label_h
    for line in spoken_lines:
        x = x0
        for tok, removed in line:
            w = text_width(tok, body_font)
            draw.text((x, y), tok, font=body_font, fill=struck if removed else PAPER)
            if removed:
                mid = y + body_size * 0.62
                draw.line((x - px(2), mid, x + w + px(2), mid), fill=struck, width=max(2, px(4)))
            x += w
        y += line_h
    y += gap
    draw.line((x0, y, card_x1 - pad, y), fill=mix(PAPER, INK, 0.18), width=max(1, px(2)))
    y += gap
    draw.text((x0, y), "打進去的", font=label_font, fill=muted)
    y += label_h
    for line in result_lines:
        draw.text((x0, y), "".join(tok for tok, _ in line), font=body_font, fill=(255, 255, 255))
        y += line_h


# ---------------------------------------------------------------------------------------------


SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(path, "PNG", icc_profile=SRGB, optimize=True)


def contact_sheet(images: list[Image.Image], path: Path) -> None:
    thumb_w = 520
    gap = 44
    thumbs = [im.resize((thumb_w, round(im.height * thumb_w / im.width)), Image.LANCZOS) for im in images]
    th = thumbs[0].height
    sheet = Image.new("RGB", (gap + len(thumbs) * (thumb_w + gap), th + 2 * gap), PAPER)
    for i, thumb in enumerate(thumbs):
        sheet.paste(thumb, (gap + i * (thumb_w + gap), gap))
    buffer = io.BytesIO()
    sheet.save(buffer, "JPEG", quality=88, optimize=True, icc_profile=SRGB)
    path.write_bytes(buffer.getvalue())


def main() -> None:
    for folder, (w, h) in SIZES.items():
        layout = Layout(w, h)
        sizes = text_sizes(layout)
        rendered = []
        for shot in SHOTS:
            image = compose(shot, layout, sizes)
            save_png(image, OUT / folder / shot.out)
            rendered.append(image)
            print(f"{folder}/{shot.out}  {image.width}x{image.height}")
        if folder == "zh-Hant":
            contact_sheet(rendered, OUT / "preview.jpg")
            print("preview.jpg")


if __name__ == "__main__":
    main()
