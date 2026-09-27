#!/usr/bin/env python3
"""
fix-deck.py — يصحّح الأخطاء القابلة للتصحيح في FLOW.pdf وينتج FLOW-corrected.pdf

النصوص في صفحتَي التنس (20 و22) محروقة داخل صور مولّدة بالذكاء الاصطناعي،
فلا يمكن تحريرها كنصّ. الحل: تغطية الكتلة المعطوبة بلون الخلفية، ثم إعادة
كتابة النصّ الصحيح فوقها بخطّ هندسي مقارب.

الطريقة:
  1. لكل خطأ، نحدّد منطقة بحث تقريبية بالنقاط (المرجع: صفحة 960×540).
  2. نرسم المنطقة بدقة عالية ونكتشف الحدود الفعلية للنصّ (بكسلات فاتحة على أسود).
  3. نغطّي الحدود المكتشفة بلون الخلفية المُلتقط من جوارها.
  4. نعيد كتابة السطور الصحيحة بحجم مشتقّ من ارتفاع النصّ الأصلي.
"""

import os
import pymupdf
from PIL import Image

SRC = "FLOW.pdf"
OUT = "FLOW-corrected.pdf"
FONT_DIR = "/mnt/skills/examples/canvas-design/canvas-fonts"
FONT_REG = os.path.join(FONT_DIR, "Outfit-Regular.ttf")
FONT_BLD = os.path.join(FONT_DIR, "Outfit-Bold.ttf")
FONT_TEK = os.path.join(FONT_DIR, "Tektur-Regular.ttf")   # وجه مربّع يقارب خطّ العرض
FONT_TEKM = os.path.join(FONT_DIR, "Tektur-Medium.ttf")

DETECT_DPI = 300          # دقة اكتشاف حدود النصّ
BRIGHT = 70               # عتبة اعتبار البكسل نصّاً على خلفية سوداء


def _region(page, clip, dpi=DETECT_DPI):
    pix = page.get_pixmap(dpi=dpi, clip=clip)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def detect_bbox(page, search, dpi=DETECT_DPI, thresh=BRIGHT, invert=False):
    """حدود النصّ الفعلية داخل منطقة البحث، بنقاط الصفحة.
    invert=True للنصّ الداكن على خلفية فاتحة."""
    clip = pymupdf.Rect(*search)
    img = _region(page, clip, dpi).convert("L")
    w, h = img.size
    px = img.load()
    hit = (lambda v: v <= thresh) if invert else (lambda v: v >= thresh)
    min_x, min_y, max_x, max_y = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if hit(px[x, y]):
                if x < min_x: min_x = x
                if x > max_x: max_x = x
                if y < min_y: min_y = y
                if y > max_y: max_y = y
    if max_x < 0:
        return None
    sx, sy = clip.width / w, clip.height / h
    return pymupdf.Rect(
        clip.x0 + min_x * sx, clip.y0 + min_y * sy,
        clip.x0 + max_x * sx + sx, clip.y0 + max_y * sy + sy,
    )


def sample_bg(page, rect, invert=False, dpi=150):
    """لون الخلفية، مُلتقط من شريط أسفل الكتلة مباشرة."""
    probe = (pymupdf.Rect(rect.x0, rect.y1 + 1.5, rect.x1, rect.y1 + 4.5)) & page.rect
    if probe.is_empty:
        return (1, 1, 1) if invert else (0, 0, 0)
    data = list(_region(page, probe, dpi).getdata())
    pick = max(data, key=sum) if invert else min(data, key=sum)
    return tuple(c / 255.0 for c in pick)


def sample_ink(page, rect, invert=False, dpi=DETECT_DPI):
    """لون النصّ الأصلي، لمطابقته عند إعادة الكتابة."""
    data = list(_region(page, rect, dpi).getdata())
    pick = min(data, key=sum) if invert else max(data, key=sum)
    return tuple(c / 255.0 for c in pick)


def _fonts(page):
    page.insert_font(fontname="outfitR", fontfile=FONT_REG)
    page.insert_font(fontname="outfitB", fontfile=FONT_BLD)
    page.insert_font(fontname="tekturR", fontfile=FONT_TEK)
    page.insert_font(fontname="tekturM", fontfile=FONT_TEKM)


def patch(page, search, lines, *, bold_first=False, color=None,
          head_color=None, size=None, leading=1.30, pad=0.8,
          invert=False, face="outfit"):
    """يغطّي الكتلة المعطوبة ويعيد كتابة السطور الصحيحة مكانها."""
    box = detect_bbox(page, search, invert=invert)
    if box is None:
        print(f"    ! لم أجد نصاً في {search}")
        return False

    ink = color if color is not None else sample_ink(page, box, invert)
    bg = sample_bg(page, box, invert)
    page.draw_rect(pymupdf.Rect(box.x0 - pad, box.y0 - pad,
                                box.x1 + pad, box.y1 + pad),
                   color=bg, fill=bg, width=0)

    n = len(lines)
    if size is None:
        size = round((box.height / n) / leading, 2) if n > 1 \
            else round(box.height / 0.72, 2)

    _fonts(page)
    reg = "tekturR" if face == "tektur" else "outfitR"
    bld = "tekturM" if face == "tektur" else "outfitB"

    y = box.y0 + size * 0.78
    for i, text in enumerate(lines):
        col = head_color if (head_color and i == 0) else ink
        page.insert_text((box.x0, y), text,
                         fontname=(bld if (bold_first and i == 0) else reg),
                         fontsize=size, color=col)
        y += size * leading

    print(f"    ✓ {lines[0][:42]:<44} size={size}")
    return True


def blank_and_write(page, rect, rows, *, bg=(0, 0, 0)):
    """يمسح مستطيلاً كاملاً ويكتب سطوراً موسّطة مكانه."""
    r = pymupdf.Rect(*rect)
    page.draw_rect(r, color=bg, fill=bg, width=0)
    _fonts(page)
    cx = (r.x0 + r.x1) / 2
    for text, y, size, col, fname, ffile in rows:
        w = pymupdf.Font(fontfile=ffile).text_length(text, fontsize=size)
        page.insert_text((cx - w / 2, y), text,
                         fontname=fname, fontsize=size, color=col)
        print(f"    ✓ {text[:46]}")


# ---------------------------------------------------------------- الإصلاحات
YELLOW = (0.85, 0.94, 0.11)
WHITE = (0.94, 0.96, 0.96)

# أحجام مقيسة من الكتل السليمة في نفس الصفحة — لا تُشتقّ، لأن صندوق البحث
# الضيّق يضخّم الحجم المشتقّ.
S_HEAD = 9.6    # عناوين الأعمدة
S_LABEL = 7.45  # تسميات الطبقات في العمود الأوسط
S_BULLET = 7.25  # نقاط تقنية القماش
S_CAP = 7.70    # تعليقات العمود الأيمن

# صفحة 22 (الفهرس 21)
P22 = [
    # (منطقة البحث, السطور الصحيحة, خيارات)
    ((784, 12, 880, 28), ["DETAILS IN 3D"],
     dict(bold_first=True, head_color=YELLOW, size=S_HEAD)),
    ((684, 58, 775, 98), ["OUTER LAYER", "Lightweight", "Performance Fabric"],
     dict(color=WHITE, bold_first=True, size=S_LABEL)),
    ((684, 128, 790, 158), ["BREATHABLE MESH", "Enhanced Ventilation"],
     dict(color=WHITE, bold_first=True, size=S_LABEL)),
    ((560, 375, 760, 404), ["Advanced moisture-wicking fibers draw sweat",
                            "away from the skin"], dict(color=WHITE, size=S_BULLET)),
    ((560, 404, 760, 433), ["Quick-dry technology keeps you fresh",
                            "through every match"], dict(color=WHITE, size=S_BULLET)),
    ((560, 433, 760, 462), ["Ultra-lightweight construction for",
                            "maximum freedom"], dict(color=WHITE, size=S_BULLET)),
    ((784, 122, 935, 150), ["Ergonomic Fit",
                            "Sculpted to support natural movement"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 241, 935, 270), ["Breathable Mesh Back",
                            "Enhances airflow and keeps you cool"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 352, 935, 381), ["Elastic Comfort Waistband",
                            "Secure fit with flexible comfort"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 464, 935, 506), ["Built-In Inner Shorts",
                            "For coverage, confidence, and",
                            "unrestricted movement"], dict(color=WHITE, size=S_CAP)),
]

# صفحة 20 (الفهرس 19) — نفس العمود الأيمن
P20 = [
    ((784, 122, 935, 150), ["Ergonomic Fit",
                            "Sculpted to support natural movement"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 241, 935, 270), ["Breathable Mesh Back",
                            "Enhances airflow and keeps you cool"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 352, 935, 381), ["Elastic Comfort Waistband",
                            "Secure fit with flexible comfort"],
     dict(color=WHITE, size=S_CAP)),
    ((784, 464, 935, 506), ["Built-In Inner Shorts",
                            "For coverage, confidence, and",
                            "unrestricted movement"], dict(color=WHITE, size=S_CAP)),
]


# ص4: «SEAMLESS COMFORT» تناقض البناء المخيط (فلاتلوك/أوفرلوك).
# البديل «CHAFE-FREE» هو المصطلح المستعمل في صفحات 15–17 نفسها.
P4 = [
    ((856, 78, 948, 95), ["CHAFE-FREE COMFORT"], dict(face="tektur", size=6.9)),
]

# «SIZE: XG» تسمية برتغالية لا تقابل جدول المقاسات XS–XL
SIZE_FIX = [
    (8,  (394, 37, 444, 55),  False),   # ص9  — نصّ داكن على أبيض
    (14, (411, 123, 458, 141), True),   # ص15 — نصّ فاتح على أسود
    (17, (398, 38, 448, 56),  False),   # ص18 — نصّ داكن على أبيض
]

LIME = (0.72, 0.87, 0.10)
AMBER = (0.95, 0.45, 0.12)
GREY = (0.60, 0.64, 0.65)


def main():
    doc = pymupdf.open(SRC)

    for idx, fixes in ((21, P22), (19, P20), (3, P4)):
        print(f"\n  صفحة {idx + 1} — نصوص معطوبة:")
        for search, lines, opts in fixes:
            patch(doc[idx], search, lines, **opts)

    print("\n  المقاسات — XG ← M:")
    for idx, search, inv in SIZE_FIX:
        print(f"    صفحة {idx + 1}")
        patch(doc[idx], search, ["SIZE: M"], invert=(not inv),
              face="tektur", size=9.0)

    # ص20: دائرة المقاس الثانية تعرض «8» بدل «S»
    print("\n  صفحة 20 — المقاس S:")
    blank_and_write(doc[19], (570.5, 494.5, 581.5, 506.5), [
        ("S", 504.9, 12.3, (1, 1, 1), "outfitR", FONT_REG),
    ])

    print("\n  صفحة 25 — حذف المقارنة بعلامة منافسة:")
    blank_and_write(doc[24], (607, 200, 886, 281), [
        ("UP TO 48 HOURS COLD", 229, 15.5, LIME, "tekturM", FONT_TEKM),
        ("UP TO 18 HOURS HOT", 253, 15.5, AMBER, "tekturM", FONT_TEKM),
        ("Target performance - to be confirmed by production testing.",
         273, 6.6, GREY, "outfitR", FONT_REG),
    ])

    doc.save(OUT, garbage=3, deflate=True)
    doc.close()
    print(f"\n  حُفظ: {OUT}  ({round(os.path.getsize(OUT)/1024/1024, 2)} MB)")


if __name__ == "__main__":
    main()
