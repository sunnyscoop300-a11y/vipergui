#!/usr/bin/env python3
"""
Helper for SJ Mini (cmd/sj). The Hare + ViperGui app calls it:

  sj.py list          fetches MANGA Plus' latest updates and writes
                      ~/.local/share/sj-mini/list.tsv (+ cover pictures)
  sj.py open <id>     opens the series in a small reader window (pywebview)
  sj.py fav <id>      makes the series a favourite, or not any more
  sj.py chapters <id> writes the free chapters to chapters-<id>.tsv
  sj.py pages <id> <chapter>
                      fetches a chapter's pages into pages/<chapter>/

Test it by hand:  python3 cmd/sj/sj.py list
"""

import io, os, re, shutil, subprocess, sys, tempfile, time, uuid
import urllib.request

DATA = os.path.expanduser("~/.local/share/sj-mini")
PICS = os.path.join(DATA, "covers")
LIST = os.path.join(DATA, "list.tsv")
LOG = os.path.join(DATA, "sj.log")
FAVS = os.path.join(DATA, "favoritter.txt")
READ = os.path.join(DATA, "laest.txt")
PAGES = os.path.join(DATA, "pages")
PAGE_H = 900                     # pages are scaled to this height (the reader scrolls)
API = "https://jumpg-webapi.tokyo-cdn.com/api"
SITE = "https://mangaplus.shueisha.co.jp"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
COVER_W, COVER_H = 156, 220
MAX = 90


def get(url, timeout=20, extra=None):
    h = {"User-Agent": UA, "Referer": SITE + "/", "Origin": SITE}
    h.update(extra or {})
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        return r.read()


def clean(s):
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


def write_atomic(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)          # the app sees the whole file at once


def write_list(lines):
    write_atomic(LIST, lines)


def fail(msg, path=None):
    write_atomic(path or LIST, ["ERR\t" + clean(msg)[:200]])
    sys.exit(1)


def api(path, what, out):
    """Calls MANGA Plus and returns the success part, or fails into out."""
    try:
        data = get(f"{API}/{path}", extra={"SESSION-TOKEN": str(uuid.uuid4())})
    except Exception as e:
        fail(f"Kunne ikke hente {what}: {e}", out)
    try:
        resp = msg(data)
    except Exception as e:
        fail(f"Forstod ikke svaret fra MANGA Plus: {e}", out)
    if 1 not in resp:
        body = ""
        try:
            pop = msg(resp[2][0])
            for k in (2, 3, 1):          # the English popup, or any
                if k in pop:
                    body = text(msg(pop[k][0]), 2)
                    if body:
                        break
        except Exception:
            pass
        fail(body or f"MANGA Plus ville ikke give os {what}.", out)
    return msg(resp[1][0])


# --- a tiny protobuf reader (MANGA Plus answers in protobuf) ---

def varint(b, i):
    n = shift = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7F) << shift
        if c < 0x80:
            return n, i
        shift += 7


def msg(b):
    """Reads one message into {field number: [values]}."""
    out, i = {}, 0
    while i < len(b):
        key, i = varint(b, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            v, i = varint(b, i)
        elif wire == 2:
            n, i = varint(b, i)
            v, i = b[i:i + n], i + n
        elif wire == 1:
            v, i = b[i:i + 8], i + 8
        elif wire == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"unknown wire type {wire}")
        out.setdefault(num, []).append(v)
    return out


def text(m, n):
    v = m.get(n)
    if not v or not isinstance(v[0], (bytes, bytearray)):
        return ""
    return v[0].decode("utf-8", "replace")


def num(m, n, default=0):
    v = m.get(n)
    return v[0] if v and isinstance(v[0], int) else default


# MangaPlusResponse.success(1) -> webHomeView(38) -> groups(2) -> titles(2)
#   UpdatedTitle: latestChapters(3) -> title(1), updatedAt(6)
#   Title: titleId(1) name(2) author(3) portraitImageUrl(4) language(7)
#   WebHomeView.featured(7) -> title(2) = UpdatedTitle

def updated_titles(home):
    for g in home.get(2, []):
        for ut in msg(g).get(2, []):
            yield msg(ut)
    for f in home.get(7, []):
        for ut in msg(f).get(2, []):
            yield msg(ut)


def ago(ts):
    if not ts:
        return ""
    s = max(0, int(time.time()) - ts)
    if s < 3600:
        return f"for {max(1, s // 60)} min siden"
    if s < 86400:
        t = s // 3600
        return f"for {t} time{'r' if t > 1 else ''} siden"
    d = s // 86400
    return f"for {d} dag{'e' if d > 1 else ''} siden"


def cover(url, tid):
    """Saves the cover as an uncompressed PNG (quick for ViperGui to open)."""
    if not url:
        return ""
    os.makedirs(PICS, exist_ok=True)
    path = os.path.join(PICS, f"{tid}.png")
    if os.path.exists(path):
        return path
    try:
        raw = get(url, timeout=15)
    except Exception as e:
        log(f"cover {tid}: {e}")
        return ""
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw)).convert("RGB")
        want = COVER_W / COVER_H
        w, h = im.size
        if w / h > want:
            nw = int(h * want)
            im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
        else:
            nh = int(w / want)
            im = im.crop((0, 0, w, nh))
        im.resize((COVER_W, COVER_H), Image.LANCZOS).save(path, compress_level=0)
        return path
    except Exception as e:
        log(f"cover {tid}: {e}")
        return ""


def log(m):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(m + "\n")


def do_list():
    try:
        data = get(f"{API}/web/web_homeV4?lang=eng&clang=eng",
                   extra={"SESSION-TOKEN": str(uuid.uuid4())})
    except Exception as e:
        fail(f"Kunne ikke hente MANGA Plus: {e}")
    try:
        resp = msg(data)
        if 1 not in resp:
            err = msg(resp[2][0]) if 2 in resp else {}
            fail("MANGA Plus svarede med en fejl. " + clean(err))
        home = msg(msg(resp[1][0])[38][0])
    except SystemExit:
        raise
    except Exception as e:
        fail(f"Forstod ikke svaret fra MANGA Plus: {e}")

    best = {}
    for ut in updated_titles(home):
        when = num(ut, 6)
        for lc in ut.get(3, []):
            t = msg(msg(lc)[1][0])
            tid = num(t, 1)
            if not tid or num(t, 7) != 0:      # English only
                continue
            row = {"id": tid, "name": text(t, 2), "author": text(t, 3).replace(" / ", ", "),
                   "img": text(t, 4), "when": when}
            if tid not in best or when > best[tid]["when"]:
                best[tid] = row
    rows = sorted(best.values(), key=lambda r: -r["when"])[:MAX]
    if not rows:
        fail("Fandt ingen opdateringer på MANGA Plus.")

    now = int(time.time())
    lines = [f"OK\t{len(rows)}"]
    for r in rows:
        fresh = "1" if r["when"] and now - r["when"] < 86400 else "0"
        lines.append("\t".join(clean(x) for x in (
            r["id"], r["name"], r["author"], ago(r["when"]), fresh, cover(r["img"], r["id"]))))
    write_list(lines)


# --- chapters and pages ---

def last_read():
    seen = {}
    try:
        for l in open(READ, encoding="utf-8"):
            p = l.split()
            if len(p) == 2:
                seen[p[0]] = p[1]
    except OSError:
        pass
    return seen


def do_chapters(tid):
    out = os.path.join(DATA, f"chapters-{tid}.tsv")
    ok = api(f"title_detailV3?title_id={tid}&clang=eng", "kapitlerne", out)
    if 8 not in ok:
        fail("Serien findes ikke længere på MANGA Plus.", out)
    view = msg(ok[8][0])
    title = msg(view[1][0]) if 1 in view else {}
    chapters = []
    for g in view.get(28, []):
        grp = msg(g)
        for n in (2, 4):                  # first chapters, newest chapters
            for c in grp.get(n, []):
                ch = msg(c)
                if 4 not in ch:           # no subtitle: expired, cannot be read
                    continue
                chapters.append(ch)
    seen = set()
    lines = [f"OK\t{clean(text(title, 2))}\t{clean(text(view, 3))}\t{last_read().get(tid, '')}"]
    for ch in chapters:
        cid = num(ch, 2)
        if cid in seen:
            continue
        seen.add(cid)
        ts = num(ch, 6)
        date = time.strftime("%d.%m.%Y", time.localtime(ts)) if ts else ""
        lines.append("\t".join(clean(x) for x in (cid, text(ch, 3), text(ch, 4), date)))
    if len(lines) == 1:
        fail("Ingen gratis kapitler lige nu.", out)
    write_atomic(out, lines)


def do_pages(tid, cid):
    folder = os.path.join(PAGES, cid)
    info = os.path.join(folder, "info.tsv")
    # Keep only this chapter's pages on disk.
    if os.path.isdir(PAGES):
        for old in os.listdir(PAGES):
            if old != cid:
                shutil.rmtree(os.path.join(PAGES, old), ignore_errors=True)
    os.makedirs(folder, exist_ok=True)
    if os.path.exists(info) and open(info).read().startswith("ERR"):
        os.remove(info)

    seen = last_read()
    seen[tid] = cid
    write_atomic(READ, [f"{k} {v}" for k, v in seen.items()])

    ok = api(f"manga_viewer_v3?chapter_id={cid}&split=yes&img_quality=high&clang=eng",
             "siderne", info)
    if 10 not in ok:
        fail("Kapitlet kan ikke læses (måske er det udløbet).", info)
    viewer = msg(ok[10][0])
    token = text(viewer, 19)
    pages = []
    for p in viewer.get(1, []):
        pm = msg(p)
        if 1 in pm:
            mp = msg(pm[1][0])
            pages.append((text(mp, 1), text(mp, 5)))
    if not pages:
        fail("Kapitlet har ingen sider.", info)
    write_atomic(info, [f"OK\t{len(pages)}"])

    from PIL import Image
    for i, (url, key) in enumerate(pages):
        path = os.path.join(folder, f"{i:03d}.png")
        if os.path.exists(path):
            continue
        try:
            raw = bytearray(get(url, timeout=30, extra={"Plus-Vw-Token": token}))
            if key:
                k = bytes.fromhex(key)
                for j in range(len(raw)):
                    raw[j] ^= k[j % len(k)]
            im = Image.open(io.BytesIO(bytes(raw))).convert("RGB")
            w = round(im.width * PAGE_H / im.height)
            tmp = path + ".tmp.png"
            im.resize((w, PAGE_H), Image.LANCZOS).save(tmp, compress_level=0)
            os.replace(tmp, path)
        except Exception as e:
            log(f"page {cid}/{i}: {e}")


def do_open(tid):
    url = f"{SITE}/titles/{tid}"
    try:
        import webview
    except ImportError:
        if shutil.which("xdg-open"):
            subprocess.Popen(["xdg-open", url])
        elif shutil.which("cmd.exe"):
            subprocess.Popen(["cmd.exe", "/c", "start", "", url], cwd="/mnt/c")
        return
    store = os.path.join(DATA, "web")
    os.makedirs(store, exist_ok=True)
    webview.create_window("SJ Mini", url, width=1000, height=900)
    webview.start(gui="gtk", private_mode=False, storage_path=store)


def do_fav(tid):
    try:
        ids = [l.strip() for l in open(FAVS, encoding="utf-8") if l.strip()]
    except OSError:
        ids = []
    if tid in ids:
        ids.remove(tid)
    else:
        ids.append(tid)
    fd, tmp = tempfile.mkstemp(dir=DATA)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("".join(i + "\n" for i in ids))
    os.replace(tmp, FAVS)


def main():
    os.makedirs(DATA, exist_ok=True)
    sys.stderr = open(LOG, "a", encoding="utf-8")
    args = sys.argv[1:]
    if args[:1] == ["list"]:
        do_list()
    elif args[:1] == ["open"] and len(args) > 1:
        do_open(args[1])
    elif args[:1] == ["fav"] and len(args) > 1:
        do_fav(args[1])
    elif args[:1] == ["chapters"] and len(args) > 1:
        do_chapters(args[1])
    elif args[:1] == ["pages"] and len(args) > 2:
        do_pages(args[1], args[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
