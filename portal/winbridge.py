"""Windows-Teil der App: das Portal als Brücke zwischen Windows, iPhone und iPad.

* Zwischenablage automatisch: Kopiertes (Text, Bilder, Dateien aus dem Explorer) landet in der Portal-Zwischenablage;
  was ein anderes Gerät dort ablegt, liegt am Laptop direkt in Strg+V (Dateien als Dateien, einfügbar im Explorer).
  Inhalte, die Passwort-Manager als „nicht aufzeichnen“ markieren, werden nie übertragen.
* Ordner „Gedankenpalast“ im Explorer, abgeglichen mit der Ablage (wie die Dateien-App am iPhone). Gelöscht wird nie.
* Rechtsklick → „Senden an“ → Gedankenpalast (Zwischenablage oder Ablage).
* Symbol im Infobereich, Start mit Windows, Mitteilungen 15 Minuten vor Terminen und am Vortag von Fristen.

Alles läuft über den Geräte-Schlüssel der App (wie Widgets und Siri am iPhone); er liegt mit Windows-DPAPI
verschlüsselt im Benutzerprofil. Die reine Logik (Planung, Namen) ist plattformunabhängig und getestet.
"""
from __future__ import annotations

import ctypes
import datetime as dt
import io
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request

IS_WIN = os.name == "nt"
DEVICE = "Windows"
FOLDER_NAME = "Gedankenpalast"
MAX_CLIP_FILE = 50 * 1024 * 1024


# ---------------------------------------------------------------- plattformunabhängige Logik (getestet)
def safe_name(name: str) -> str:
    """Datei- oder Ordnername, den Windows annimmt."""
    n = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name or "").strip().rstrip(". ")
    if re.fullmatch(r"(?i)(con|prn|aux|nul|com\d|lpt\d)(\..*)?", n):
        n = "_" + n
    return n[:150] or "Datei"


def plan_downloads(files: list[dict], known: dict[str, str]) -> list[tuple[dict, str]]:
    """Welche Ablage-Dateien neu in den Ordner kommen: (Datei, relativer Pfad). „Wohin damit?“ liegt im Hauptordner."""
    taken = {v.lower() for v in known.values()}
    out = []
    for f in files:
        if f["id"] in known:
            continue
        folder = "" if f.get("pending") else safe_name(f.get("folder") or "Allgemein")
        base = safe_name(f.get("name") or "Datei")
        rel = os.path.join(folder, base) if folder else base
        stem, ext = os.path.splitext(rel)
        i = 2
        while rel.lower() in taken:
            rel = f"{stem} ({i}){ext}"
            i += 1
        taken.add(rel.lower())
        out.append((f, rel))
    return out


def plan_uploads(local: list[tuple[str, float, int]], known: dict[str, str], now: float) -> list[tuple[str, str | None]]:
    """Neue lokale Dateien (relativer Pfad, Änderungszeit, Größe) → (Pfad, Ablage-Ordner oder None für „Wohin damit?“).
    Nur fertig geschriebene (seit 10 s unverändert), keine versteckten/temporären."""
    mine = {v.lower() for v in known.values()}
    out = []
    for rel, mtime, size in local:
        name = os.path.basename(rel)
        if rel.lower() in mine or name.startswith(("~$", ".")) or name.lower().endswith((".tmp", ".part", ".crdownload", ".ini")):
            continue
        if now - mtime < 10 or size <= 0 or size > 200 * 1024 * 1024:
            continue
        parts = rel.replace("\\", "/").split("/")
        out.append((rel, None if len(parts) == 1 else parts[0]))
    return out


def due_alerts(data: dict, now: dt.datetime, sent: set[str]) -> list[tuple[str, str, str, str]]:
    """Fällige Mitteilungen aus /api/app/data: (Schlüssel, Titel, Text, Bereich). Termine 15 Min. vorher, Fristen am Vortag 18 Uhr."""
    out = []
    for e in data.get("events") or []:
        if not e.get("zeit") or not e.get("datum"):
            continue
        try:
            start = dt.datetime.strptime(f"{e['datum']} {e['zeit']}", "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        key = f"t|{e['datum']}|{e['zeit']}|{e.get('titel')}"
        if key not in sent and start - dt.timedelta(minutes=15) <= now < start:
            body = " · ".join(x for x in [e["zeit"] + (f"–{e['ende']}" if e.get("ende") else ""), e.get("raum")] if x)
            out.append((key, e.get("titel") or "Termin", "In 15 Minuten · " + body, "kalender"))
    for d in data.get("deadlines") or []:
        day = (d.get("datum") or "")[:10]
        try:
            at = dt.datetime.strptime(day, "%Y-%m-%d") - dt.timedelta(hours=6)   # Vortag 18 Uhr
        except ValueError:
            continue
        key = f"f|{day}|{d.get('titel')}"
        if key not in sent and at <= now < at + dt.timedelta(hours=6):
            pre = "Prüfung morgen: " if d.get("art") == "pruefung" else "Frist morgen: "
            out.append((key, pre + (d.get("titel") or ""), d.get("kurs") or "", "studium"))
    return out


# ---------------------------------------------------------------- Verbindung zum Portal
class Portal:
    def __init__(self, base: str, key: str):
        self.base, self.key = base, key

    def _req(self, path, data=None, headers=None, timeout=60):
        h = {"X-App-Key": self.key, "User-Agent": "Studienportal-App (Windows)", **(headers or {})}
        req = urllib.request.Request(self.base + path, data=data, headers=h, method="POST" if data is not None else "GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read(), r.headers

    def action(self, act: str, **body):
        raw, _ = self._req("api/app/action", json.dumps({"action": act, **body}).encode(), {"Content-Type": "application/json"})
        return json.loads(raw)

    def download(self, act: str, id: str) -> tuple[bytes, str]:
        raw, hd = self._req("api/app/action", json.dumps({"action": act, "id": id}).encode(), {"Content-Type": "application/json"}, 300)
        return raw, urllib.parse.unquote(hd.get("X-Filename") or "Datei")

    def upload(self, data: bytes, name: str, ctype: str = "application/octet-stream", folder: str | None = None, clip: bool = False) -> dict:
        q = "?clip=1" if clip else (f"?folder={urllib.parse.quote(folder)}" if folder else "")
        raw, _ = self._req("api/app/upload" + q, data, {"X-Filename": urllib.parse.quote(name), "Content-Type": ctype}, 300)
        return json.loads(raw)


# ---------------------------------------------------------------- DPAPI (Schlüssel verschlüsselt speichern)
class _Blob(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.POINTER(ctypes.c_char))]


def protect(text: str) -> str:
    if not IS_WIN:
        return text
    import base64
    data = text.encode()
    src = _Blob(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = _Blob()
    if not ctypes.windll.crypt32.CryptProtectData(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError("DPAPI")
    res = ctypes.string_at(out.pbData, out.cbData)
    ctypes.windll.kernel32.LocalFree(out.pbData)
    return "dpapi:" + base64.b64encode(res).decode()


def unprotect(text: str) -> str:
    if not text or not text.startswith("dpapi:") or not IS_WIN:
        return text or ""
    import base64
    data = base64.b64decode(text[6:])
    src = _Blob(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = _Blob()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out)):
        return ""
    res = ctypes.string_at(out.pbData, out.cbData)
    ctypes.windll.kernel32.LocalFree(out.pbData)
    return res.decode()


# ---------------------------------------------------------------- Windows-Zwischenablage (ctypes)
CF_UNICODETEXT, CF_DIB, CF_HDROP = 13, 8, 15
GMEM_MOVEABLE = 0x0002

if IS_WIN:
    from ctypes import wintypes
    user32, kernel32, shell32 = ctypes.windll.user32, ctypes.windll.kernel32, ctypes.windll.shell32
    user32.OpenClipboard.argtypes = [wintypes.HWND]; user32.OpenClipboard.restype = wintypes.BOOL
    user32.GetClipboardData.argtypes = [wintypes.UINT]; user32.GetClipboardData.restype = wintypes.HANDLE
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]; user32.SetClipboardData.restype = wintypes.HANDLE
    user32.IsClipboardFormatAvailable.argtypes = [wintypes.UINT]; user32.IsClipboardFormatAvailable.restype = wintypes.BOOL
    user32.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]; user32.RegisterClipboardFormatW.restype = wintypes.UINT
    user32.GetClipboardSequenceNumber.restype = wintypes.DWORD
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]; kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]; kernel32.GlobalLock.restype = wintypes.LPVOID
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalSize.argtypes = [wintypes.HGLOBAL]; kernel32.GlobalSize.restype = ctypes.c_size_t
    shell32.DragQueryFileW.argtypes = [wintypes.HANDLE, wintypes.UINT, wintypes.LPWSTR, wintypes.UINT]; shell32.DragQueryFileW.restype = wintypes.UINT


class Clipboard:
    """Lesen/Schreiben der Windows-Zwischenablage: Text, Bild (DIB ↔ PNG), Dateiliste (CF_HDROP)."""

    def __init__(self):
        self.skip = [user32.RegisterClipboardFormatW(n) for n in
                     ("ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore")] if IS_WIN else []
        self.no_history = user32.RegisterClipboardFormatW("CanIncludeInClipboardHistory") if IS_WIN else 0
        self.no_cloud = user32.RegisterClipboardFormatW("CanUploadToCloudClipboard") if IS_WIN else 0

    @staticmethod
    def seq() -> int:
        return user32.GetClipboardSequenceNumber() if IS_WIN else 0

    def _open(self):
        for _ in range(20):
            if user32.OpenClipboard(None):
                return True
            time.sleep(0.05)
        return False

    def _get(self, fmt) -> bytes | None:
        h = user32.GetClipboardData(fmt)
        if not h:
            return None
        p = kernel32.GlobalLock(h)
        if not p:
            return None
        try:
            return ctypes.string_at(p, kernel32.GlobalSize(h))
        finally:
            kernel32.GlobalUnlock(h)

    def _dword_zero(self, fmt) -> bool:
        if not fmt or not user32.IsClipboardFormatAvailable(fmt):
            return False
        d = self._get(fmt)
        return bool(d) and len(d) >= 4 and int.from_bytes(d[:4], "little") == 0

    def read(self):
        """→ ("text", str) | ("image", png-bytes) | ("files", [Pfade]) | ("private", None) | None"""
        if not self._open():
            return None
        try:
            if any(f and user32.IsClipboardFormatAvailable(f) for f in self.skip) or self._dword_zero(self.no_history) or self._dword_zero(self.no_cloud):
                return ("private", None)   # Passwort-Manager u. Ä.: nie übertragen
            if user32.IsClipboardFormatAvailable(CF_HDROP):
                h = user32.GetClipboardData(CF_HDROP)
                n = shell32.DragQueryFileW(h, 0xFFFFFFFF, None, 0)
                paths = []
                for i in range(n):
                    ln = shell32.DragQueryFileW(h, i, None, 0)
                    buf = ctypes.create_unicode_buffer(ln + 1)
                    shell32.DragQueryFileW(h, i, buf, ln + 1)
                    paths.append(buf.value)
                return ("files", paths)
            if user32.IsClipboardFormatAvailable(CF_DIB):
                dib = self._get(CF_DIB)
                if dib:
                    return ("image", dib_to_png(dib))
            if user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
                raw = self._get(CF_UNICODETEXT) or b""
                text = raw.decode("utf-16-le", "ignore").split("\x00", 1)[0]
                return ("text", text) if text.strip() else None
            return None
        finally:
            user32.CloseClipboard()

    def _set(self, fmt, data: bytes) -> bool:
        h = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        p = kernel32.GlobalLock(h)
        ctypes.memmove(p, data, len(data))
        kernel32.GlobalUnlock(h)
        return bool(user32.SetClipboardData(fmt, h))

    def write(self, kind: str, value) -> bool:
        if not self._open():
            return False
        try:
            user32.EmptyClipboard()
            if kind == "text":
                return self._set(CF_UNICODETEXT, (value + "\x00").encode("utf-16-le"))
            if kind == "image":
                return self._set(CF_DIB, png_to_dib(value))
            if kind == "files":
                # DROPFILES { DWORD pFiles; POINT pt; BOOL fNC; BOOL fWide } + Pfade (UTF-16, doppelt nullterminiert)
                head = (20).to_bytes(4, "little") + b"\x00" * 8 + b"\x00" * 4 + (1).to_bytes(4, "little")
                body = "".join(p + "\x00" for p in value).encode("utf-16-le") + b"\x00\x00"
                return self._set(CF_HDROP, head + body)
            return False
        finally:
            user32.CloseClipboard()


def dib_to_png(dib: bytes) -> bytes:
    from PIL import Image
    # BITMAPFILEHEADER davor setzen, dann liest Pillow das Bild wie eine .bmp-Datei
    hsize = int.from_bytes(dib[:4], "little")
    bits = int.from_bytes(dib[14:16], "little")
    colors = int.from_bytes(dib[32:36], "little") if hsize >= 36 else 0
    comp = int.from_bytes(dib[16:20], "little") if hsize >= 20 else 0
    masks = 12 if comp == 3 and hsize == 40 else 0
    pal = (colors or (1 << bits if bits <= 8 else 0)) * 4
    off = 14 + hsize + masks + pal
    bmp = b"BM" + (14 + len(dib)).to_bytes(4, "little") + b"\x00\x00\x00\x00" + off.to_bytes(4, "little") + dib
    im = Image.open(io.BytesIO(bmp))
    out = io.BytesIO()
    im.convert("RGBA" if im.mode in ("RGBA", "LA", "P") else "RGB").save(out, "PNG")
    return out.getvalue()


def png_to_dib(png: bytes) -> bytes:
    from PIL import Image
    im = Image.open(io.BytesIO(png)).convert("RGB")
    out = io.BytesIO()
    im.save(out, "BMP")
    return out.getvalue()[14:]   # ohne BITMAPFILEHEADER


# ---------------------------------------------------------------- Abgleich-Dienste
class Bridge:
    """Hintergrund-Dienste der Windows-App. settings: dict (wird über save() gespeichert)."""

    def __init__(self, settings: dict, save, notify, show):
        self.s, self._save, self.notify, self.show = settings, save, notify, show
        self.data_dir = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "Studienportal")
        self.root = os.path.join(os.path.expanduser("~"), FOLDER_NAME)
        self.cb = Clipboard() if IS_WIN else None
        self.ignore_seq = -1
        self.writing = False   # gerade selbst in die Zwischenablage geschrieben → nicht zurückschicken
        self.last_sent = None
        self.stop = threading.Event()

    # Einstellungen
    def opt(self, k, default=True):
        return self.s.get(k, default)

    def set_opt(self, k, v):
        self.s[k] = v
        self._save(self.s)

    @property
    def portal(self) -> Portal | None:
        key = unprotect(self.s.get("key") or "")
        return Portal(self.s["url"], key) if key and self.s.get("url") else None

    def start(self):
        for fn in (self._clip_out_loop, self._clip_in_loop, self._folder_loop, self._alert_loop):
            threading.Thread(target=self._guard, args=(fn,), daemon=True).start()

    def _guard(self, fn):
        while not self.stop.is_set():
            try:
                fn()
            except Exception as exc:   # nie abstürzen – kurz warten, weiter
                print("Brücke:", fn.__name__, exc)
                time.sleep(15)

    # --- Zwischenablage: Laptop → Portal
    def _clip_out_loop(self):
        seq = Clipboard.seq()
        while not self.stop.is_set():
            time.sleep(0.7)
            now = Clipboard.seq()
            if now == seq:
                continue
            seq = now
            if self.writing or now == self.ignore_seq or not self.opt("clipSync") or not self.portal:
                continue
            time.sleep(0.3)   # Programme schreiben mehrere Formate nacheinander
            got = self.cb.read()
            if not got or got[0] == "private":
                continue
            self.send_clip(*got)

    def send_clip(self, kind, value, quiet=True):
        p = self.portal
        if not p:
            return 0
        sig = (kind, value if kind != "image" else len(value))
        if sig == self.last_sent:
            return 0
        self.last_sent = sig
        if kind == "text":
            p.action("clip", text=value[:200000])
            return 1
        if kind == "image":
            p.upload(value, f"Bild_{dt.datetime.now():%Y-%m-%d_%H%M%S}.png", "image/png", clip=True)
            return 1
        n = 0
        if kind == "files":
            if not self.opt("clipFiles") and quiet:
                return 0
            files = [f for f in value if os.path.isfile(f)]
            if not files or len(files) > 10 or sum(os.path.getsize(f) for f in files) > MAX_CLIP_FILE:
                if not quiet:
                    self.notify("Zu groß für die Zwischenablage", "Höchstens 10 Dateien und 50 MB – größere über „Senden an → Ablage“.")
                return 0
            for f in files:
                with open(f, "rb") as fh:
                    p.upload(fh.read(), os.path.basename(f), _mime(f), clip=True)
                n += 1
        return n

    # --- Zwischenablage: Portal → Laptop
    def _clip_in_loop(self):
        since = None
        seen = set(self.s.get("clipSeen") or [])
        while not self.stop.is_set():
            time.sleep(3)
            p = self.portal
            if not p or not self.opt("clipSync"):
                continue
            if since is None:   # beim Start nichts Altes übernehmen
                since = p.action("clipsSince", since=10 ** 12).get("latest") or 0
                continue
            res = p.action("clipsSince", since=since)
            since = res.get("latest") or since
            clips = [c for c in res.get("clips") or [] if c.get("id") not in seen]
            if not clips:
                continue
            seen.update(c["id"] for c in clips)
            self.s["clipSeen"] = sorted(seen)[-200:]
            self._save(self.s)
            self.receive(clips[-1])

    def receive(self, c):
        self.writing = True
        try:
            self._receive(c)
        finally:
            self.ignore_seq = Clipboard.seq()
            time.sleep(1)   # die Abfrage der Zwischenablage hat die Änderung dann sicher gesehen
            self.writing = False

    def _receive(self, c):
        p = self.portal
        kind = c.get("kind")
        if kind in ("text", "link"):
            ok = self.cb.write("text", c.get("text") or "")
            what = f"„{(c.get('text') or '')[:60]}“"
        elif kind == "image":
            data, _ = p.download("clipFile", c["id"])
            ok = self.cb.write("image", data)
            what = "Bild"
        else:
            data, name = p.download("clipFile", c["id"])
            folder = os.path.join(self.data_dir, "Zwischenablage")
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, safe_name(c.get("name") or name))
            with open(path, "wb") as f:
                f.write(data)
            ok = self.cb.write("files", [path])
            what = f"„{c.get('name')}“"
        if ok:
            self.last_sent = (("text", c.get("text")) if kind in ("text", "link") else None)
            self.notify(f"Von {c.get('device') or 'anderem Gerät'} in der Zwischenablage", f"{what} – mit Strg+V einfügen")

    # --- Ordner „Gedankenpalast“ ↔ Ablage
    def _map_path(self):
        return os.path.join(self.data_dir, "ordner.json")

    def _load_map(self) -> dict:
        try:
            with open(self._map_path(), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def _store_map(self, m):
        os.makedirs(self.data_dir, exist_ok=True)
        with open(self._map_path(), "w", encoding="utf-8") as f:
            json.dump(m, f)

    def sync_folder(self):
        p = self.portal
        if not p or not self.opt("folderSync"):
            return
        os.makedirs(self.root, exist_ok=True)
        known = self._load_map()
        files = p.action("files").get("files") or []
        for f, rel in plan_downloads(files, known):
            dest = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if not os.path.exists(dest):
                data, _ = p.download("file", f["id"])
                with open(dest + ".part", "wb") as fh:
                    fh.write(data)
                os.replace(dest + ".part", dest)
            known[f["id"]] = rel
            self._store_map(known)
        local = []
        for dirpath, dirs, names in os.walk(self.root):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for n in names:
                full = os.path.join(dirpath, n)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                local.append((os.path.relpath(full, self.root), st.st_mtime, st.st_size))
        for rel, folder in plan_uploads(local, known, time.time()):
            with open(os.path.join(self.root, rel), "rb") as fh:
                res = p.upload(fh.read(), os.path.basename(rel), _mime(rel), folder=folder)
            fid = (res.get("file") or {}).get("id")
            known[fid or ("lokal-" + rel)] = rel
            self._store_map(known)
            if folder is None:
                self.notify("In der Ablage", f"„{os.path.basename(rel)}“ wartet unter „Wohin damit?“.")

    def _folder_loop(self):
        while not self.stop.is_set():
            self.sync_folder()
            self.stop.wait(60)

    # --- Mitteilungen zu Terminen und Fristen
    def _alert_loop(self):
        sent = set(self.s.get("alertsSent") or [])
        while not self.stop.is_set():
            p = self.portal
            if p and self.opt("alerts"):
                raw, _ = p._req("api/app/data")
                for key, title, body, route in due_alerts(json.loads(raw), dt.datetime.now(), sent):
                    self.notify(title, body, route)
                    sent.add(key)
                self.s["alertsSent"] = sorted(sent)[-300:]
                self._save(self.s)
            self.stop.wait(60)

    # --- „Senden an“
    def send_paths(self, paths: list[str], to_clip: bool) -> int:
        p = self.portal
        if not p:
            self.notify("Gedankenpalast", "Bitte die App einmal öffnen und anmelden.")
            return 0
        n = 0
        for f in paths:
            if not os.path.isfile(f):
                continue
            size = os.path.getsize(f)
            if size > (MAX_CLIP_FILE if to_clip else 200 * 1024 * 1024):
                self.notify("Zu groß", f"„{os.path.basename(f)}“ ist zu groß.")
                continue
            with open(f, "rb") as fh:
                p.upload(fh.read(), os.path.basename(f), _mime(f), clip=to_clip)
            n += 1
        if n:
            self.notify("Gesendet", (f"{n} Datei(en) in der Zwischenablage" if to_clip else f"{n} Datei(en) in der Ablage unter „Wohin damit?“"))
        return n


def _mime(path: str) -> str:
    import mimetypes
    return mimetypes.guess_type(path)[0] or "application/octet-stream"
