#!/usr/bin/env python3
"""
Helper for Wolt Mini (cmd/wolt). The Hare + ViperGui app calls it:

  wolt.py list ["address"]   finds restaurants near the address and writes
                             ~/.local/share/wolt-mini/list.tsv (+ pictures)
  wolt.py open <slug>        opens the restaurant in a small browser window
                             (pywebview), where you order and pay as normal

Test it by hand:  python3 cmd/wolt/wolt.py list "Rødekro"
"""

import io, json, os, re, shutil, subprocess, sys, tempfile, unicodedata
import urllib.parse, urllib.request

DATA = os.path.expanduser("~/.local/share/wolt-mini")
PICS = os.path.join(DATA, "pics")
LIST = os.path.join(DATA, "list.tsv")
ADDR = os.path.join(DATA, "address.txt")
LOG = os.path.join(DATA, "wolt.log")
UA = "Mozilla/5.0 (X11; Linux x86_64) WoltMini/1.0 (ViperGui hobby app)"
PIC_W, PIC_H = 336, 150
MAX = 60


def get(url, data=None, timeout=20):
    req = urllib.request.Request(url, data=data, headers={
        "User-Agent": UA,
        "Accept": "application/json, */*",
        "Accept-Language": "da-DK,da;q=0.9,en;q=0.5",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def clean(s):
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


def write_list(lines):
    os.makedirs(DATA, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DATA)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, LIST)          # the app sees the whole file at once


def fail(msg):
    write_list(["ERR\t" + clean(msg)[:200]])
    sys.exit(1)


# --- where are we? ---

def geocode(address):
    q = urllib.parse.urlencode({"q": address, "format": "json", "limit": 1,
                                "countrycodes": "dk"})
    found = json.loads(get("https://nominatim.openstreetmap.org/search?" + q))
    if not found:
        fail(f"Kunne ikke finde adressen: {address}")
    return float(found[0]["lat"]), float(found[0]["lon"])


# --- restaurants ---

def venues_in(node, out):
    """Finds every {"venue": {...}} in Wolt's page, however it is nested."""
    if isinstance(node, dict):
        v = node.get("venue")
        if isinstance(v, dict) and v.get("slug"):
            out.append((node, v))
        for x in node.values():
            venues_in(x, out)
    elif isinstance(node, list):
        for x in node:
            venues_in(x, out)


def estimate(v):
    r = v.get("estimate_range")
    if r:
        return f"{r} min"
    e = v.get("estimate")
    return f"{e} min" if e else ""


def fee(v):
    p = v.get("delivery_price")
    if isinstance(p, str) and p:
        return p
    for key in ("delivery_price_int", "delivery_price"):
        p = v.get(key)
        if isinstance(p, (int, float)):
            return f"{p / 100:.0f} kr" if p else "Gratis levering"
    return ""


def rating(v):
    r = v.get("rating")
    if isinstance(r, dict):
        s = r.get("score") or r.get("rating")
        if s:
            return f"{s}"
    return ""


def picture(url, slug):
    """Saves the venue's picture as a PNG (what ViperGui reads)."""
    if not url:
        return ""
    os.makedirs(PICS, exist_ok=True)
    path = os.path.join(PICS, re.sub(r"[^a-zA-Z0-9_-]", "_", slug) + ".png")
    if os.path.exists(path):
        return path
    try:
        sep = "&" if "?" in url else "?"
        raw = get(f"{url}{sep}w=600", timeout=15)
    except Exception:
        return ""
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw)).convert("RGB")
        # Cut to the card's shape, then scale.
        want = PIC_W / PIC_H
        w, h = im.size
        if w / h > want:
            nw = int(h * want)
            im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
        else:
            nh = int(w / want)
            im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
        im.resize((PIC_W, PIC_H), Image.LANCZOS).save(path)
        return path
    except ImportError:
        pass
    except Exception:
        return ""
    # No Pillow: try ImageMagick.
    tool = shutil.which("magick") or shutil.which("convert")
    if not tool:
        return ""
    src = path + ".src"
    with open(src, "wb") as f:
        f.write(raw)
    try:
        subprocess.run([tool, src, "-resize", f"{PIC_W}x{PIC_H}^", "-gravity", "center",
                        "-extent", f"{PIC_W}x{PIC_H}", path],
                       check=True, capture_output=True, timeout=30)
    except Exception:
        return ""
    finally:
        os.remove(src)
    return path if os.path.exists(path) else ""


def do_list(address):
    if not address:
        try:
            address = open(ADDR, encoding="utf-8").read().strip()
        except OSError:
            address = ""
    address = address or "Rødekro"
    os.makedirs(DATA, exist_ok=True)
    with open(ADDR, "w", encoding="utf-8") as f:
        f.write(address + "\n")

    try:
        lat, lon = geocode(address)
    except SystemExit:
        raise
    except Exception as e:
        fail(f"Adresse-opslag fejlede: {e}")

    try:
        page = json.loads(get(
            f"https://consumer-api.wolt.com/v1/pages/restaurants?lat={lat}&lon={lon}"))
    except Exception as e:
        fail(f"Kunne ikke hente Wolt: {e}")

    found = []
    venues_in(page, found)
    seen, rows = set(), []
    for item, v in found:
        slug = v["slug"]
        if slug in seen:
            continue
        seen.add(slug)
        img = (item.get("image") or {}).get("url") or (v.get("image") or {}).get("url", "")
        rows.append({
            "slug": slug,
            "name": v.get("name") or item.get("title") or slug,
            "desc": v.get("short_description") or "",
            "est": estimate(v),
            "fee": fee(v),
            "rating": rating(v),
            "online": "1" if v.get("online", True) else "0",
            "url": v.get("public_url") or "",
            "city": v.get("city") or "",
            "img": img,
        })
    if not rows:
        fail(f"Wolt leverer ikke til {address} lige nu (ingen steder fundet).")

    rows.sort(key=lambda r: r["online"] != "1")    # open places first
    rows = rows[:MAX]
    lines = [f"OK\t{clean(address)[:60]}\t{len(rows)}"]
    for r in rows:
        path = picture(r["img"], r["slug"])
        lines.append("\t".join(clean(x) for x in (
            r["slug"], r["name"], r["desc"], r["est"], r["fee"], r["rating"],
            r["online"], path, r["url"], r["city"])))
    write_list(lines)


# --- open a restaurant ---

def slugify(s):
    s = s.lower().replace("æ", "ae").replace("ø", "oe").replace("å", "aa")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def venue_url(slug, url, city):
    if not url:
        try:
            info = json.loads(get(f"https://restaurant-api.wolt.com/v3/venues/slug/{slug}"))
            res = (info.get("results") or [{}])[0]
            url = res.get("public_url") or ""
            city = city or res.get("city") or ""
        except Exception:
            pass
    if not url:
        url = f"https://wolt.com/da/dnk/{slugify(city or 'aabenraa')}/restaurant/{slug}"
    return re.sub(r"wolt\.com/[a-z]{2}/", "wolt.com/da/", url)


def do_open(slug, url="", city=""):
    url = venue_url(slug, url, city)
    try:
        import webview
    except ImportError:
        # No pywebview: use the normal browser instead.
        if shutil.which("xdg-open"):
            subprocess.Popen(["xdg-open", url])
        elif shutil.which("cmd.exe"):
            subprocess.Popen(["cmd.exe", "/c", "start", "", url], cwd="/mnt/c")
        return
    store = os.path.join(DATA, "web")       # keeps you logged in
    os.makedirs(store, exist_ok=True)
    webview.create_window("Wolt Mini", url, width=1100, height=800)
    try:
        webview.start(gui="gtk", private_mode=False, storage_path=store)
    except TypeError:                       # old pywebview
        webview.start(gui="gtk")


def main():
    os.makedirs(DATA, exist_ok=True)
    sys.stderr = open(LOG, "a", encoding="utf-8")
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    if args[0] == "list":
        do_list(" ".join(args[1:]).strip())
    elif args[0] == "open" and len(args) >= 2:
        do_open(args[1], args[2] if len(args) > 2 else "", args[3] if len(args) > 3 else "")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
