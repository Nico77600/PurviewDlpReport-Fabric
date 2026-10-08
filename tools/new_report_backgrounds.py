# Purview DLP Report for Microsoft Fabric - design of the Power BI report.
# Draws the page backgrounds with the visual identity of the HTML report and of the guide (warm background, white
# cards with soft shadows, crimson accent, gradient tiles with icons and rings, header band) and writes the
# position of every visual slot to layout.json. The visuals of the report are transparent and placed in the slots.
#
#   python tools/new_report_backgrounds.py      -> package/src/report/bg-*.png (2560 x 1440) + package/src/report/layout.json
#
# Needs: pip install playwright ; Microsoft Edge installed (used as the browser, nothing is downloaded).
import json, os
from playwright.sync_api import sync_playwright

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "package", "src", "report")
C = dict(bg="#f7f4ef", surface="#ffffff", border="#dedede", text="#242424", muted="#5c5c5c", soft="#6f6f6f",
         accent="#b11f4b", accent2="#9a1a41", asoft="rgba(177,31,75,0.08)", hi="rgba(177,31,75,0.12)")
BANDS = [("26-30 recipients", "#e3879f"), ("31-40 recipients", "#c9416a"), ("41-60 recipients", "#a51d45"), ("61+ recipients", "#6e1230")]
SHADOW = "box-shadow:0 1px 2px rgba(36,36,36,.04),0 10px 28px rgba(36,36,36,.06);"

ICONS = {
    "shield": '<path d="M12 3 4 6v6c0 5 3.4 8.3 8 9 4.6-.7 8-4 8-9V6z"/><path d="m9 12 2 2 4-4"/>',
    "mail": '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m3 6 9 7 9-7"/>',
    "user": '<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
    "bars": '<path d="M4 20V10m8 10V4m8 16V7"/>',
    "people": '<circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20v-1a6 6 0 0 1 12 0v1m2-5a4.5 4.5 0 0 1 5 4.5V20"/>',
    "filter": '<path d="M4 5h16l-6 7v6l-4 2v-8z"/>',
    "calendar": '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4m8-4v4"/>',
    "layers": '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    "trend": '<path d="M3 17l6-6 4 4 8-8"/><path d="M14 7h7v7"/>',
    "trophy": '<path d="M8 4h8v5a4 4 0 0 1-8 0z"/><path d="M8 6H5a3 3 0 0 0 3 4m8-4h3a3 3 0 0 1-3 4M12 13v4m-4 3h8"/>',
    "tree": '<rect x="9" y="3" width="6" height="5" rx="1.5"/><rect x="3" y="16" width="6" height="5" rx="1.5"/><rect x="15" y="16" width="6" height="5" rx="1.5"/><path d="M12 8v4M6 16v-4h12v4"/>',
    "grid": '<rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="8" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/><rect x="13" y="13" width="8" height="8" rx="2"/>',
    "table": '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 9h18M3 14h18M9 9v11"/>',
    "eye": '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    "database": '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    "wrench": '<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>',
    "chat": '<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>',
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
}

def icon(name, size, color, opacity=1, width=1.7):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linecap="round" stroke-linejoin="round" style="opacity:{opacity};display:block">{ICONS[name]}</svg>')

def div(x, y, w, h, style="", inner=""):
    return f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;box-sizing:border-box;{style}">{inner}</div>'

def label(text, color=None, size=11):
    return (f'<span style="font-size:{size}px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;'
            f'color:{color or C["accent"]};white-space:nowrap">{text}</span>')

def chip(name, size=26, radius=8):
    return (f'<div style="width:{size}px;height:{size}px;border-radius:{radius}px;background:{C["asoft"]};display:flex;'
            f'align-items:center;justify-content:center;flex:none">{icon(name, int(size * .58), C["accent"])}</div>')

def card(x, y, w, h, title=None, ic=None, note=""):
    head = ""
    if title:
        head = div(14, 12, w - 28, 26, "display:flex;align-items:center;gap:10px",
                   chip(ic) + label(title) + (f'<span style="margin-left:auto;font-size:11px;color:{C["soft"]}">{note}</span>' if note else ""))
    return div(x, y, w, h, f"background:{C['surface']};border:1px solid {C['border']};border-radius:14px;{SHADOW}", head)

def ring(right, bottom, size, width, color):
    return f'<div style="position:absolute;right:{right}px;bottom:{bottom}px;width:{size}px;height:{size}px;border:{width}px solid {color};border-radius:50%"></div>'

def header(title, subtitle, box_label, box_icon):
    inner = (ring(-100, -110, 280, 40, C["hi"])
             + div(20, 16, 44, 44, f"border-radius:12px;background:linear-gradient(135deg,{C['accent2']},{C['accent']});display:flex;align-items:center;justify-content:center;box-shadow:0 6px 16px rgba(177,31,75,.28)", icon("shield", 24, "#ffffff", 1, 1.8))
             + div(80, 10, 760, 18, "", label("Purview DLP / Exchange"))
             + div(80, 25, 760, 32, f"font-size:24px;font-weight:650;letter-spacing:-.02em;color:{C['text']};white-space:nowrap", title)
             + div(80, 55, 780, 18, f"font-size:12px;color:{C['muted']};white-space:nowrap", subtitle)
             + div(888, 11, 344, 54, f"background:{C['surface']};border:1px solid {C['border']};border-radius:12px",
                   div(0, 7, 344, 16, "display:flex;justify-content:center;align-items:center;gap:6px", icon(box_icon, 13, C["accent"]) + label(box_label, size=10))))
    style = (f"border:1px solid {C['border']};border-top:4px solid {C['accent']};border-radius:16px;overflow:hidden;"
             f"background:linear-gradient(125deg,{C['surface']} 38%,#f6e4ea);{SHADOW}")
    return div(16, 12, 1248, 80, style, inner), {"range": [918, 45, 316, 30]}

def tile(x, y, w, h, kind, title, caption, ic):
    if kind == "primary":
        bg, fg, sub, rc = f"linear-gradient(125deg,{C['accent2']},{C['accent']})", "#ffffff", "rgba(255,255,255,.88)", "rgba(255,255,255,.16)"
        extra = "box-shadow:0 10px 26px rgba(177,31,75,.28);border:1px solid " + C["accent"] + ";"
    elif kind == "tinted":
        bg, fg, sub, rc, extra = f"linear-gradient(135deg,{C['surface']},#f8e8ed)", C["text"], C["muted"], C["hi"], f"border:1px solid {C['border']};{SHADOW}"
    else:
        bg, fg, sub, rc, extra = C["surface"], C["text"], C["muted"], C["hi"], f"border:1px solid {C['border']};{SHADOW}"
    inner = (ring(-28, -32, 84, 14, rc)
             + div(0, 9, w, 18, f"text-align:center;font-size:12px;font-weight:600;color:{fg}", title)
             + div(w - 32, 10, 20, 20, "", icon(ic, 17, fg, .7))
             + div(0, h - 21, w, 16, f"text-align:center;font-size:10.5px;color:{sub}", caption))
    return div(x, y, w, h, f"border-radius:16px;overflow:hidden;background:{bg};{extra}", inner)

def filters_panel():
    fields = [("date", "Date", 80), ("line", "Business line", 36), ("entity", "Entity", 36), ("site", "Site", 36),
              ("mgr2", "Manager N+2", 36), ("mgr", "Manager", 36), ("sender", "Sender", 36)]
    inner, slots, y = "", {}, 52
    for key, text, h in fields:
        inner += div(14, y, 200, 14, "", label(text, C["soft"], 10))
        slots["f_" + key] = [16 + 8, 100 + y + 16, 212, h]
        y += 16 + h + 10
    inner += div(14, 608 - 50, 200, 40, f"font-size:10.5px;line-height:1.45;color:{C['soft']}",
                 "Filters apply to the whole page.<br>Ctrl + click a bar to filter by it.")
    head = div(14, 12, 200, 26, "display:flex;align-items:center;gap:10px", chip("filter") + label("Filters"))
    return div(16, 100, 228, 608, f"background:{C['surface']};border:1px solid {C['border']};border-radius:14px;{SHADOW}", head + inner), slots

SUB = "Messages sent to more than 25 recipients &#183; one row per message &#183; you see the messages that concern you"

def chart_slot(x, y, w, h):
    return [x + 8, y + 44, w - 16, h - 52]

def page_overview():
    hdr, slots = header("Message activity", SUB, "Detection time range", "calendar")
    fp, fslots = filters_panel(); slots.update(fslots)
    body = hdr + fp
    tw = (1008 - 3 * 12) / 4
    tiles = [("primary", "Matching messages", "Unique Message IDs", "mail"), ("tinted", "Active senders", "Distinct senders", "user"),
             ("tinted", "Average recipients", "Recipients per message", "bars"), ("plain", "Largest audience", "Highest recipient count", "people")]
    for i, (k, t, c, ic) in enumerate(tiles):
        x = 256 + i * (tw + 12)
        body += tile(x, 100, tw, 80, k, t, c, ic)
        slots[f"tile{i + 1}"] = [x + 10, 100 + 23, tw - 20, 42]
    # Recipient count strip: title on the left, a thin 100% bar on the right and, under it, one column per band
    # (static swatch + label in the background, dynamic "count · share" card placed by the report).
    strip = card(256, 188, 1008, 84, "Recipient count", "bars")
    extra = (div(50, 44, 230, 16, f"font-size:10.5px;color:{C['soft']};white-space:nowrap", "share of the matching messages")
             + div(292, 10, 1, 64, f"background:{C['border']}"))
    bx, bw = 556, 694
    colw = bw / 4
    for i, (n, c) in enumerate(BANDS):
        cx = bx + i * colw - 256
        extra += div(cx, 58, 60, 16, f"display:flex;align-items:center;gap:6px;font-size:11px;font-weight:600;color:{C['muted']};white-space:nowrap",
                     f'<span style="width:10px;height:10px;border-radius:3px;background:{c}"></span>{n.split(" ")[0]}')
        slots[f"band{i + 1}"] = [bx + i * colw + 50, 188 + 52, colw - 56, 28]
    body += strip.replace("</div></div>", "</div>" + extra + "</div>", 1)
    slots["strip"] = [bx, 182, bw, 72]
    for key, (x, y, w, h, t, ic, note) in {
        "byline": (256, 280, 498, 204, "Messages by business line", "layers", ""),
        "perday": (766, 280, 498, 204, "Messages per day", "trend", ""),
        "topsenders": (256, 492, 498, 216, "Top 10 senders", "trophy", "by messages"),
        "topmanagers": (766, 492, 498, 216, "Top 10 managers", "people", "messages of their teams"),
    }.items():
        body += card(x, y, w, h, t, ic, note)
        slots[key] = chart_slot(x, y, w, h)
    return body, slots

def page_messages():
    hdr, slots = header("Messages", SUB, "Detection time range", "calendar")
    fp, fslots = filters_panel(); slots.update(fslots)
    body = hdr + fp + card(256, 100, 1008, 608, "One row per message", "table", "newest first &#183; scroll for more columns")
    slots["table"] = [264, 144, 992, 556]
    return body, slots

def page_hierarchy():
    hdr, slots = header("Business lines and managers", SUB, "Detection time range", "calendar")
    fp, fslots = filters_panel(); slots.update(fslots)
    body = hdr + fp + card(256, 100, 616, 608, "Business line &#8250; manager &#8250; sender", "tree", "expand the rows with +")
    body += card(884, 100, 380, 608, "Where the messages come from", "grid", "by manager")
    slots["matrix"] = [264, 144, 600, 556]
    slots["treemap"] = [892, 144, 364, 556]
    return body, slots

INFO = [
    ("eye", "What you see", "Each row is one e-mail sent to <b>more than 25 recipients</b> and detected by the DLP policy. You see your own messages, the messages of the people who report to you &#8212; directly or not &#8212; and the business lines you follow as a correspondent. The compliance team sees every message.", ""),
    ("database", "Where the data comes from", "Microsoft Purview Activity Explorer, collected by <b>Purview DLP Report</b> and published <b>once a day</b>. Business line, entity, site and manager come from the company directory (Microsoft Entra ID) on the day of the publication.", ""),
    ("wrench", "If a row seems wrong", "A wrong business line or manager is corrected <b>in the directory</b>, not in this report. The next publication takes the change into account for the whole period.", ""),
    ("chat", "Ask in plain language", "Open the data agent in <b>Microsoft 365 Copilot</b> or Teams and ask, for example:",
     "&#171; Pour le service Finance, quels exp&#233;diteurs d&#233;passent 25 destinataires&#8239;? &#187;"),
]

def page_about():
    hdr, slots = header("About this report", SUB, "Detection time range", "calendar")
    body = hdr
    cw, ch = (856 - 12) / 2, (608 - 12) / 2
    for i, (ic, title, text, quote) in enumerate(INFO):
        x, y = 16 + (i % 2) * (cw + 12), 100 + (i // 2) * (ch + 12)
        q = (f'<div style="position:relative;margin-top:14px;padding:12px 14px;border-radius:12px;background:#fbeef2;border-left:3px solid {C["accent"]};'
             f'font-size:13px;font-style:italic;color:{C["text"]}">{quote}</div><div style="margin-top:10px;font-size:12px;color:{C["soft"]}">The agent sees the same scope as you.</div>') if quote else ""
        inner = (ring(-36, -40, 110, 18, C["hi"])
                 + div(24, 24, 44, 44, "", chip(ic, 44, 12))
                 + div(24, 84, cw - 48, 26, f"font-size:18px;font-weight:650;color:{C['text']}", title)
                 + div(24, 118, cw - 48, ch - 130, f"z-index:2;font-size:13.5px;line-height:1.6;color:{C['muted']}", text + q))
        body += div(x, y, cw, ch, f"background:{C['surface']};border:1px solid {C['border']};border-radius:16px;overflow:hidden;{SHADOW}", inner)
    body += card(884, 100, 380, 608, "Last publication", "calendar")
    for i, (kind, title, caption) in enumerate([("plain", "Published", "UTC &#183; once a day"), ("tinted", "Period", "days published"),
                                                ("primary", "Messages in your scope", "messages you can see"), ("plain", "Coverage", "share of the period collected by the tool")]):
        y = 144 + i * 140
        body += tile(896, y, 356, 128, kind, title, caption, ["clock", "calendar", "mail", "shield"][i])
        slots[f"pub{i + 1}"] = [896 + 12, y + 38, 356 - 24, 54]
    return body, slots

def html(body):
    return (f'<html><head><style>body{{margin:0}}*{{font-family:"Segoe UI Variable Text","Segoe UI",sans-serif}}</style></head>'
            f'<body><div style="position:relative;width:1280px;height:720px;overflow:hidden;background:{C["bg"]}">{body}</div></body></html>')

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    layout = {}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="msedge", headless=True)
        page = browser.new_page(viewport={"width": 1280, "height": 720}, device_scale_factor=2)
        for name, fn in {"overview": page_overview, "messages": page_messages, "hierarchy": page_hierarchy, "about": page_about}.items():
            body, slots = fn()
            page.set_content(html(body))
            page.wait_for_timeout(200)
            path = os.path.join(OUT, f"bg-{name}.png")
            page.screenshot(path=path, clip={"x": 0, "y": 0, "width": 1280, "height": 720})
            layout[name] = {k: [round(v, 1) for v in s] for k, s in slots.items()}
            print(f"bg-{name}.png", os.path.getsize(path) // 1024, "KB,", len(slots), "slots")
        browser.close()
    layout["bands"] = [{"name": n, "color": c} for n, c in BANDS]
    with open(os.path.join(OUT, "layout.json"), "w", encoding="utf-8") as f:
        json.dump(layout, f, indent=1)
    print("layout.json written")
