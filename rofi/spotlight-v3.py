#!/usr/bin/env python3
import os, re, sys, json, time, shlex, subprocess, hashlib
from pathlib import Path
from urllib.parse import quote_plus
import xml.etree.ElementTree as ET

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "rofi-spotlight-v3"
CACHE.mkdir(parents=True, exist_ok=True)

APPS_JSON   = CACHE / "apps.json"
APPS_SIG    = CACHE / "apps.sig"
RECENT_JSON = CACHE / "recent.json"
RECENT_SIG  = CACHE / "recent.sig"
HIST_DB     = CACHE / "history.json"
MIME_ICON_JSON = CACHE / "mime_icons.json"
DEBUG_LOG   = CACHE / "debug.log"

# This is the key fix: rofi build doesn't pass ROFI_INFO reliably,
# so we maintain a "last render map" of label -> TYPE|ID|PAYLOAD.
LAST_MAP = CACHE / "last_map.tsv"

MAX_ROWS = 120

def log(msg: str):
    ts = time.strftime("%F %T")
    with open(DEBUG_LOG, "a", encoding="utf-8") as f:
        f.write(f"[{ts}] {msg}\n")

def has(cmd: str) -> bool:
    return subprocess.call(["bash", "-lc", f"command -v {shlex.quote(cmd)} >/dev/null 2>&1"]) == 0

def run_bg(cmd: str):
    subprocess.Popen(["bash", "-lc", cmd],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)

def xdg_open(target: str):
    run_bg(f"xdg-open {shlex.quote(target)}")

def kitty_cmd(cmd: str) -> str:
    if has("kitty"):
        return f"kitty sh -lc {shlex.quote(cmd)}"
    if has("alacritty"):
        return f"alacritty -e sh -lc {shlex.quote(cmd)}"
    return f"xterm -e sh -lc {shlex.quote(cmd)}"

def clip_copy(s: str):
    if has("xclip"):
        p = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
        p.communicate(s.encode("utf-8", "ignore"))
    elif has("wl-copy"):
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
        p.communicate(s.encode("utf-8", "ignore"))

def looks_like_url(s: str) -> bool:
    s = s.strip()
    return bool(re.match(r"^(https?://|www\.)\S+$", s))

def normalize_url(s: str) -> str:
    s = s.strip()
    if s.startswith(("http://", "https://")):
        return s
    if s.startswith("www."):
        return "https://" + s
    return s

# ---------------- Frecency ----------------
def load_hist():
    if HIST_DB.exists():
        try:
            return json.loads(HIST_DB.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}

def save_hist(h):
    HIST_DB.write_text(json.dumps(h, indent=2), encoding="utf-8")

def bump_hist(item_id: str):
    h = load_hist()
    now = int(time.time())
    ent = h.get(item_id, {"count": 0, "last": 0})
    ent["count"] = int(ent.get("count", 0)) + 1
    ent["last"] = now
    h[item_id] = ent
    save_hist(h)

def frecency_score(item_id: str, base_priority: int = 0) -> int:
    h = load_hist()
    ent = h.get(item_id)
    if not ent:
        return base_priority
    count = int(ent.get("count", 0))
    last = int(ent.get("last", 0))
    age = max(0, int(time.time()) - last)
    rec = max(0, 500000 - age)
    return base_priority + count * 2000 + rec

# ------------- MIME icon cache -------------
def load_mime_icons():
    if MIME_ICON_JSON.exists():
        try:
            return json.loads(MIME_ICON_JSON.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}

def save_mime_icons(m):
    MIME_ICON_JSON.write_text(json.dumps(m, indent=2), encoding="utf-8")

MIME_ICONS = load_mime_icons()

def guess_icon_for_path(p: str) -> str:
    path = Path(p)
    if path.is_dir():
        return "folder"

    ext = path.suffix.lower().lstrip(".")
    if ext in ("png","jpg","jpeg","webp","gif","svg"):
        return "image-x-generic"
    if ext in ("pdf",):
        return "application-pdf"
    if ext in ("zip","tar","gz","xz","zst","7z","rar"):
        return "package-x-generic"
    if ext in ("mp3","flac","wav","m4a","ogg"):
        return "audio-x-generic"
    if ext in ("mp4","mkv","webm","avi"):
        return "video-x-generic"
    if ext in ("tex","bib"):
        return "text-x-tex"
    if ext in ("py","c","cpp","h","hpp","rs","go","js","ts","lua","sh","zsh"):
        return "text-x-script"
    if ext in ("md","txt","log","yaml","yml","toml","json","ini","conf"):
        return "text-x-generic"

    key = str(path)
    if key in MIME_ICONS:
        return MIME_ICONS[key]

    # Best-effort MIME guess, silent if file disappears
    if has("xdg-mime") and path.exists():
        try:
            out = subprocess.check_output(
                ["xdg-mime", "query", "filetype", key],
                text=True, stderr=subprocess.DEVNULL
            ).strip()
            icon = "text-x-generic"
            if out.startswith("image/"):
                icon = "image-x-generic"
            elif out.startswith("audio/"):
                icon = "audio-x-generic"
            elif out.startswith("video/"):
                icon = "video-x-generic"
            elif out == "application/pdf":
                icon = "application-pdf"
            elif out.startswith("application/"):
                icon = "application-x-executable"
            MIME_ICONS[key] = icon
            save_mime_icons(MIME_ICONS)
            return icon
        except Exception:
            pass

    return "text-x-generic"

# ---------------- Apps provider ----------------
DESKTOP_DIRS = [Path("/usr/share/applications"), HOME / ".local/share/applications"]

def desktop_sig() -> str:
    parts = []
    for d in DESKTOP_DIRS:
        if d.exists():
            try:
                st = d.stat()
                parts.append(f"{d}:{int(st.st_mtime)}")
                parts.append(f"n={sum(1 for _ in d.glob('*.desktop'))}")
            except Exception:
                parts.append(f"{d}:err")
    return "|".join(parts)

_exec_placeholder = re.compile(r"%[fFuUdDnNickvm]")

def sanitize_exec(exec_line: str) -> str:
    s = _exec_placeholder.sub("", exec_line)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def parse_desktop_file(fp: Path):
    in_entry = False
    name = exec_line = icon = ""
    nodisplay = False

    try:
        for raw in fp.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line == "[Desktop Entry]":
                in_entry = True
                continue
            if line.startswith("[") and line.endswith("]") and line != "[Desktop Entry]":
                in_entry = False
                continue
            if not in_entry or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()

            if k == "NoDisplay" and v.lower() == "true":
                nodisplay = True
            elif k == "Name" and not name:
                name = v
            elif k == "Exec" and not exec_line:
                exec_line = v
            elif k == "Icon" and not icon:
                icon = v
    except Exception:
        return None

    if nodisplay or not name or not exec_line:
        return None

    exec_line = sanitize_exec(exec_line)
    if not exec_line:
        return None

    return name, exec_line, (icon or "application-x-executable")

def build_apps():
    apps = []
    for d in DESKTOP_DIRS:
        if not d.exists():
            continue
        for f in d.glob("*.desktop"):
            parsed = parse_desktop_file(f)
            if not parsed:
                continue
            name, exec_line, icon = parsed
            item_id = f"app:{f.name}"

            # Include desktop filename lightly to avoid collisions (still Spotlight-ish)
            label = f"{name}  [app]"
            apps.append({
                "label": label,
                "type": "APP",
                "id": item_id,
                "payload": exec_line,
                "icon": icon,
                "prio": 9000,
            })
    return apps

def ensure_apps_cache():
    sig = desktop_sig()
    old = APPS_SIG.read_text(encoding="utf-8") if APPS_SIG.exists() else ""
    if APPS_JSON.exists() and old == sig:
        return
    log("build_apps_cache")
    apps = build_apps()
    APPS_JSON.write_text(json.dumps(apps), encoding="utf-8")
    APPS_SIG.write_text(sig, encoding="utf-8")

def load_apps():
    ensure_apps_cache()
    try:
        return json.loads(APPS_JSON.read_text(encoding="utf-8"))
    except Exception:
        return []

# ---------------- Recent provider ----------------
XBEL = HOME / ".local/share/recently-used.xbel"

def recent_sig() -> str:
    if not XBEL.exists():
        return "missing"
    st = XBEL.stat()
    return f"{int(st.st_mtime)}:{st.st_size}"

def build_recent(limit=250):
    items = []
    if not XBEL.exists():
        return items
    try:
        tree = ET.parse(str(XBEL))
        root = tree.getroot()
        for bm in root.findall(".//bookmark"):
            href = bm.get("href", "")
            if not href.startswith("file://"):
                continue
            path = href.replace("file://", "", 1).replace("%20", " ")
            if not path or not os.path.exists(path):
                continue
            name = os.path.basename(path) or path
            item_id = f"file:{path}"
            items.append({
                "label": f"{name}  [recent]",
                "type": "FILE",
                "id": item_id,
                "payload": path,
                "icon": guess_icon_for_path(path),
                "prio": 6000,
            })
            if len(items) >= limit:
                break
    except Exception:
        pass
    return items

def ensure_recent_cache():
    sig = recent_sig()
    old = RECENT_SIG.read_text(encoding="utf-8") if RECENT_SIG.exists() else ""
    if RECENT_JSON.exists() and old == sig:
        return
    log("build_recent_cache")
    items = build_recent()
    RECENT_JSON.write_text(json.dumps(items), encoding="utf-8")
    RECENT_SIG.write_text(sig, encoding="utf-8")

def load_recent():
    ensure_recent_cache()
    try:
        return json.loads(RECENT_JSON.read_text(encoding="utf-8"))
    except Exception:
        return []

# ---------------- plocate provider ----------------
def plocate_search(q: str, limit=80):
    if len(q) < 3 or not has("plocate"):
        return []
    try:
        out = subprocess.check_output(
            ["plocate", "-i", "--limit", str(limit), "--", q],
            text=True, stderr=subprocess.DEVNULL
        )
        items = []
        for p in out.splitlines():
            p = p.strip()
            if not p:
                continue
            if not os.path.exists(p):
                continue
            name = os.path.basename(p) or p
            item_id = f"file:{p}"
            items.append({
                "label": f"{name}  [file]",
                "type": "FILE",
                "id": item_id,
                "payload": p,
                "icon": guess_icon_for_path(p),
                "prio": 4000,
            })
        return items
    except Exception:
        return []

# ---------------- calculator ----------------
MATH_RE = re.compile(r"^[0-9\s+\-*/().]+$")

def calc_item(q: str):
    q = q.strip()
    if not q or not MATH_RE.match(q):
        return None
    try:
        res = eval(q, {"__builtins__": {}}, {})
        if isinstance(res, (int, float)):
            item_id = f"calc:{q}={res}"
            return {"label": f"= {res}  [calc copy]", "type": "CALC", "id": item_id,
                    "payload": str(res), "icon": "accessories-calculator", "prio": 9500}
    except Exception:
        return None
    return None

def web_item(q: str):
    q = q.strip()
    return {"label": f"Search web: {q}  [web]", "type": "WEB", "id": f"web:{q}",
            "payload": q, "icon": "web-browser", "prio": 1000}

def rofi_line(label: str, icon: str) -> str:
    # Only icon metadata; don't rely on ROFI_INFO (your build doesn't pass it)
    return f"{label}\0icon\x1f{icon}"

def write_last_map(rows):
    # rows: list of (label, "TYPE|ID|PAYLOAD")
    with open(LAST_MAP, "w", encoding="utf-8") as f:
        for label, packed in rows:
            # TAB-separated, label can contain spaces but not TAB (we don't emit TAB)
            f.write(label.replace("\t", " ") + "\t" + packed.replace("\n", " ") + "\n")

def lookup_last_map(label: str):
    if not LAST_MAP.exists():
        return None
    try:
        with open(LAST_MAP, "r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                k, v = line.split("\t", 1)
                if k == label:
                    return v
    except Exception:
        return None
    return None

def list_phase(q: str):
    q = q or ""
    qs = q.strip()

    items = []
    c = calc_item(qs)
    if c: items.append(c)

    # Apps ALWAYS present
    items.extend(load_apps())
    items.extend(load_recent())

    # plocate as you type
    items.extend(plocate_search(qs))

    items.append(web_item(qs))

    # dedupe by id
    seen = set()
    dedup = []
    for it in items:
        if not it: continue
        if it["id"] in seen: continue
        seen.add(it["id"])
        dedup.append(it)

    scored = []
    for it in dedup:
        scored.append((frecency_score(it["id"], it.get("prio", 0)), it))

    scored.sort(key=lambda x: x[0], reverse=True)
    scored = scored[:MAX_ROWS]

    # Build and write selection map
    map_rows = []
    for _, it in scored:
        packed = f'{it["type"]}|{it["id"]}|{it["payload"]}'
        map_rows.append((it["label"], packed))
    write_last_map(map_rows)

    # Emit rofi lines
    for _, it in scored:
        sys.stdout.write(rofi_line(it["label"], it["icon"]) + "\n")

def selection_phase(q: str):
    retv = int(os.environ.get("ROFI_RETV", "1"))
    raw = (q or "").strip()
    info = os.environ.get("ROFI_INFO", "")  # may be empty on your build
    log(f"ROFI_RETV={retv} raw='{raw}' info='{info}'")

    # First try our robust map (works even if ROFI_INFO is empty)
    packed = lookup_last_map(raw)

    # If still nothing, treat raw as free input fallback
    if not packed:
        s = raw
        if not s:
            return
        p = os.path.expanduser(s)
        if os.path.exists(p):
            xdg_open(p); return
        if looks_like_url(s):
            xdg_open(normalize_url(s)); return
        run_bg(s); return

    parts = packed.split("|", 2)
    if len(parts) != 3:
        run_bg(raw); return

    typ, item_id, payload = parts
    bump_hist(item_id)

    # custom keys:
    # 10 Ctrl+Enter  | 11 Alt+Enter (copy) | 12 Shift+Enter (reveal)
    if retv == 11:
        clip_copy(payload); return
    if retv == 12:
        if typ == "FILE":
            xdg_open(str(Path(payload).expanduser().resolve().parent))
        else:
            clip_copy(payload)
        return
    if retv == 10:
        if typ == "FILE":
            run_bg(kitty_cmd(f"xdg-open {shlex.quote(payload)}"))
        elif typ == "WEB":
            url = "https://duckduckgo.com/?q=" + quote_plus(payload)
            run_bg(kitty_cmd(f"xdg-open {shlex.quote(url)}"))
        else:
            run_bg(kitty_cmd(payload))
        return

    # default Enter
    if typ == "APP":
        run_bg(payload)
    elif typ == "FILE":
        xdg_open(payload)
    elif typ == "CALC":
        clip_copy(payload)
    elif typ == "WEB":
        url = "https://duckduckgo.com/?q=" + quote_plus(payload)
        xdg_open(url)
    else:
        run_bg(payload)

def main():
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    if os.environ.get("ROFI_RETV", "0") != "0":
        selection_phase(q)
    else:
        list_phase(q)

if __name__ == "__main__":
    main()
