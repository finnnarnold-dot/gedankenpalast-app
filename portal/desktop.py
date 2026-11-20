"""Studienportal als Windows-App: eigenes Fenster (WebView2) statt Browser-Tab.

* Beim ersten Start installiert sich die App selbst nach %LOCALAPPDATA%\\Programs\\Studienportal
  und legt Einträge im Startmenü und auf dem Desktop an.
* Fragt einmal nach der Adresse deines Portals, die Anmeldung bleibt gespeichert.
* Inhalte kommen vom Server – Verbesserungen sind sofort da. Die App selbst holt neue Versionen
  über deinen Server (der sie mit seinem GitHub-Lese-Schlüssel bezieht) und tauscht sich beim Schließen aus.
* Windows-Mitteilungen (z. B. „Routine fertig“) über die Brücke window.pywebview.api.notify.
* Brücke zu iPhone/iPad (portal/winbridge.py): Zwischenablage automatisch, Ordner „Gedankenpalast“ im Explorer,
  „Senden an“, Symbol im Infobereich (läuft im Hintergrund weiter), Start mit Windows, Mitteilungen zu Terminen.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

from . import config as C

APP_NAME = "Studienportal"
AUMID = "FinnArnold.Studienportal"
BASE = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "Programs", APP_NAME)
DATA = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), APP_NAME)
INSTALLED_EXE = os.path.join(BASE, APP_NAME + ".exe")
SETTINGS = os.path.join(DATA, "app.json")
NO_WINDOW = 0x08000000   # CREATE_NO_WINDOW


def _load() -> dict:
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save(d: dict) -> None:
    os.makedirs(DATA, exist_ok=True)
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)


def _vtuple(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v or "0")[:3])


def normalize_url(u: str) -> str | None:
    u = (u or "").strip()
    if not u:
        return None
    if not re.match(r"^https?://", u, re.I):
        u = "https://" + u
    p = urllib.parse.urlsplit(u)
    if not p.netloc or p.scheme not in ("https", "http"):
        return None
    host = (p.hostname or "").lower()
    # wie in der iPhone-App: „1-2-3-4“ oder „1.2.3.4“ → 1-2-3-4.sslip.io
    if re.fullmatch(r"\d{1,3}(-\d{1,3}){3}", host) or re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", host):
        host = host.replace(".", "-") + ".sslip.io"
        return f"https://{host}{':' + str(p.port) if p.port else ''}/"
    if p.scheme == "http" and not p.hostname in ("localhost", "127.0.0.1"):
        return None   # nur verschlüsselt (außer am eigenen Rechner)
    return f"{p.scheme}://{p.netloc}/"


# ---------------------------------------------------------------- Installation
def _powershell(script: str, timeout=30) -> bool:
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
                           capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW if os.name == "nt" else 0)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _shortcut(path: str, target: str, args: str = "", desc: str = "Studienportal") -> None:
    t = target.replace("'", "''")
    p = path.replace("'", "''")
    a = args.replace("'", "''")
    _powershell(f"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{p}');$s.TargetPath='{t}';$s.Arguments='{a}';"
                f"$s.WorkingDirectory='{os.path.dirname(t)}';$s.IconLocation='{t},0';$s.Description='{desc}';$s.Save()")


def _integrate(exe: str) -> None:
    """Einmal je Version: „Senden an“, Link-Protokoll gedankenpalast://, Ordner im Schnellzugriff."""
    s = _load()
    if s.get("integrated") == C.VERSION or os.name != "nt":
        return
    sendto = os.path.join(os.environ.get("APPDATA", ""), r"Microsoft\Windows\SendTo")
    if os.path.isdir(sendto):
        _shortcut(os.path.join(sendto, "Gedankenpalast (Zwischenablage).lnk"), exe, "--send-clip", "In die Gedankenpalast-Zwischenablage")
        _shortcut(os.path.join(sendto, "Gedankenpalast (Ablage).lnk"), exe, "--send-ablage", "In die Ablage (Wohin damit?)")
    try:
        import winreg
        k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Classes\gedankenpalast")
        winreg.SetValueEx(k, "", 0, winreg.REG_SZ, "URL:Gedankenpalast")
        winreg.SetValueEx(k, "URL Protocol", 0, winreg.REG_SZ, "")
        c = winreg.CreateKey(k, r"shell\open\command")
        winreg.SetValueEx(c, "", 0, winreg.REG_SZ, f'"{exe}" --open "%1"')
        winreg.CloseKey(c); winreg.CloseKey(k)
    except Exception:
        pass
    from . import winbridge
    os.makedirs(os.path.join(os.path.expanduser("~"), winbridge.FOLDER_NAME), exist_ok=True)
    folder = os.path.join(os.path.expanduser("~"), winbridge.FOLDER_NAME).replace("'", "''")
    threading.Thread(target=_powershell, args=(f"(New-Object -ComObject shell.application).Namespace('{folder}').Self.InvokeVerb('pintohome')",), daemon=True).start()
    if "autostart" not in s:
        s["autostart"] = True
        set_autostart(True, exe)
    s["integrated"] = C.VERSION
    _save(s)


def set_autostart(on: bool, exe: str | None = None) -> None:
    try:
        import winreg
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE)
        if on:
            winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ, f'"{exe or os.path.abspath(sys.executable)}" --background')
        else:
            try:
                winreg.DeleteValue(k, APP_NAME)
            except FileNotFoundError:
                pass
        winreg.CloseKey(k)
    except Exception:
        pass


def _register_notifications() -> None:
    """Mitteilungen mit Namen und Symbol „Studienportal“ (Registrierung für Apps ohne Paket)."""
    try:
        import winreg
        k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, rf"Software\Classes\AppUserModelId\{AUMID}")
        winreg.SetValueEx(k, "DisplayName", 0, winreg.REG_SZ, APP_NAME)
        ico = os.path.join(BASE, "icon.ico")
        if os.path.exists(ico):
            winreg.SetValueEx(k, "IconUri", 0, winreg.REG_SZ, ico)
        winreg.CloseKey(k)
    except Exception:
        pass


def install_if_needed() -> bool:
    """Läuft die App nicht aus dem Installationsordner, dorthin kopieren, Verknüpfungen anlegen und neu starten."""
    if not getattr(sys, "frozen", False) or os.name != "nt":
        return False
    me = os.path.abspath(sys.executable)
    if os.path.normcase(me) == os.path.normcase(INSTALLED_EXE):
        return False
    os.makedirs(BASE, exist_ok=True)
    try:
        shutil.copy2(me, INSTALLED_EXE)
    except OSError:
        return False   # z. B. läuft schon eine installierte App → dann einfach diese Datei benutzen
    ico = os.path.join(getattr(sys, "_MEIPASS", ""), "web", "icons", "icon.ico")
    if os.path.exists(ico):
        shutil.copy2(ico, os.path.join(BASE, "icon.ico"))
    start_menu = os.path.join(os.environ.get("APPDATA", ""), r"Microsoft\Windows\Start Menu\Programs", APP_NAME + ".lnk")
    desktop = os.path.join(os.path.expanduser("~"), "Desktop", APP_NAME + ".lnk")
    _shortcut(start_menu, INSTALLED_EXE)
    _shortcut(desktop, INSTALLED_EXE)
    _register_notifications()
    subprocess.Popen([INSTALLED_EXE], close_fds=True)
    return True


# ---------------------------------------------------------------- Mitteilungen
def notify(title: str, body: str, route: str = "") -> None:
    if os.name != "nt":
        return
    esc = lambda s: (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&apos;")[:240]
    r = re.sub(r"[^a-z0-9/-]", "", route or "")
    launch = f" activationType='protocol' launch='gedankenpalast://{r}'" if r else ""
    actions = f"<actions><action content='Öffnen' activationType='protocol' arguments='gedankenpalast://{r}'/></actions>" if r else ""
    xml = (f"<toast{launch}><visual><binding template='ToastGeneric'><text>{esc(title)}</text><text>{esc(body)}</text></binding></visual>"
           f"{actions}</toast>").replace("'", "''")
    script = ("[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null;"
              "[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null;"
              f"$x = New-Object Windows.Data.Xml.Dom.XmlDocument; $x.LoadXml('{xml}');"
              f"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{AUMID}').Show("
              "[Windows.UI.Notifications.ToastNotification]::new($x))")
    threading.Thread(target=_powershell, args=(script,), daemon=True).start()


# ---------------------------------------------------------------- Selbst-Update
class Updater:
    def __init__(self):
        self.ready = None   # Pfad zur heruntergeladenen neuen Version

    def check(self, base_url: str, cookies: str, on_ready) -> None:
        try:
            req = urllib.request.Request(base_url + "api/app/windows", headers={"Cookie": cookies, "User-Agent": "Studienportal-App"})
            with urllib.request.urlopen(req, timeout=20) as r:
                info = json.loads(r.read())
            if not info.get("version") or _vtuple(info["version"]) <= _vtuple(C.VERSION):
                return
            tmp = os.path.join(tempfile.gettempdir(), f"Studienportal-{info['version']}.exe")
            req = urllib.request.Request(base_url + "api/app/windows/download", headers={"Cookie": cookies, "User-Agent": "Studienportal-App"})
            with urllib.request.urlopen(req, timeout=300) as r, open(tmp + ".part", "wb") as f:
                shutil.copyfileobj(r, f)
            if os.path.getsize(tmp + ".part") < 1_000_000:
                return
            os.replace(tmp + ".part", tmp)
            self.ready = tmp
            on_ready(info["version"])
        except Exception:
            pass

    def apply_on_exit(self) -> None:
        """Nach dem Schließen: neue Datei an die Stelle der alten kopieren (wenn die App beendet ist)."""
        if not self.ready or os.name != "nt" or not getattr(sys, "frozen", False):
            return
        target = os.path.abspath(sys.executable)
        bat = os.path.join(tempfile.gettempdir(), "studienportal-update.cmd")
        with open(bat, "w", encoding="utf-8") as f:
            f.write(f'@echo off\r\nfor /l %%i in (1,1,30) do (\r\n  timeout /t 1 /nobreak >nul\r\n'
                    f'  copy /y "{self.ready}" "{target}" >nul 2>&1 && goto done\r\n)\r\n:done\r\ndel "{self.ready}" >nul 2>&1\r\n')
        subprocess.Popen(["cmd", "/c", bat], creationflags=NO_WINDOW, close_fds=True)


# ---------------------------------------------------------------- Fenster
SETUP_HTML = """<!doctype html><html lang=de><meta charset=utf-8><title>Studienportal</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;background:#121110;color:#f5f2ed;font:15px 'Segoe UI',system-ui,sans-serif}
.box{width:min(460px,90vw);padding:30px;border-radius:24px;background:#1f1c19;border:1px solid rgba(255,248,235,.11)}
h1{margin:0 0 6px;font-size:26px}p{color:#c2bbb1;line-height:1.5}input{width:100%;box-sizing:border-box;padding:12px 14px;border-radius:12px;border:1px solid rgba(255,248,235,.2);background:#0e0d0c;color:inherit;font:inherit}
button{margin-top:14px;width:100%;padding:12px;border:0;border-radius:14px;background:#cdd5a4;color:#1d2111;font:600 15px inherit;cursor:pointer}#err{color:#e5604f;min-height:1.2em}</style>
<div class=box><h1>Studienportal</h1><p>Adresse deines Portals – so wie du sie im Browser öffnest, z.&nbsp;B. <b>1-2-3-4.sslip.io</b> oder kurz die Zahlen mit Bindestrichen (<b>1-2-3-4</b>).</p>
<input id=u placeholder="https://…" autofocus autocapitalize=none spellcheck=false><div id=err></div><button id=b>Verbinden</button></div>
<script>
// Die Verbindung zur App (window.pywebview.api) steht erst kurz nach dem Laden bereit – bis dahin warten statt still nichts zu tun
const err=document.getElementById('err'),btn=document.getElementById('b'),inp=document.getElementById('u');
const ready=new Promise(r=>{if(window.pywebview&&window.pywebview.api&&window.pywebview.api.set_url)r();else window.addEventListener('pywebviewready',r,{once:true})});
const go=async()=>{err.textContent='';btn.disabled=true;btn.textContent='Verbinde …';
  try{await ready;const r=await window.pywebview.api.set_url(inp.value);if(!r.ok)err.textContent=r.detail}
  catch(e){err.textContent='Fehler: '+(e&&e.message||e)}
  btn.disabled=false;btn.textContent='Verbinden'};
btn.onclick=go;inp.onkeydown=e=>{if(e.key==='Enter')go()};</script></html>"""


class Api:
    def __init__(self):
        self.window = None

    def set_url(self, u):
        url = normalize_url(u)
        if not url:
            return {"ok": False, "detail": "Bitte eine Adresse mit https eingeben."}
        try:
            with urllib.request.urlopen(urllib.request.Request(url + "login.html", headers={"User-Agent": "Studienportal-App"}), timeout=15) as r:
                if r.status != 200:
                    raise OSError(f"HTTP {r.status}")
        except Exception as exc:
            return {"ok": False, "detail": f"Unter {url} antwortet kein Studienportal ({str(exc)[:120]})."}
        s = _load()
        s["url"] = url
        _save(s)
        self.window.load_url(url)
        return {"ok": True}

    def notify(self, title, body=""):
        notify(str(title), str(body))
        return True

    def info(self):
        return {"version": C.VERSION, "platform": "windows"}

    def change_url(self):
        self.window.load_html(SETUP_HTML)
        return True


def _cookies(w) -> str:
    try:
        return "; ".join(f"{c.key}={c.value}" for jar in (w.get_cookies() or []) for c in jar.values())
    except Exception:
        return ""


def _ensure_key(w, settings: dict) -> bool:
    """Geräte-Schlüssel holen, sobald im Fenster angemeldet (wie Widgets/Siri am iPhone)."""
    from . import winbridge
    if settings.get("key") or not settings.get("url"):
        return bool(settings.get("key"))
    cookies = _cookies(w)
    if not cookies:
        return False
    try:
        name = "Windows (" + (os.environ.get("COMPUTERNAME") or "Laptop") + ")"
        req = urllib.request.Request(settings["url"] + "api/app/key", data=json.dumps({"device": name}).encode(), method="POST",
                                     headers={"Cookie": cookies, "Content-Type": "application/json", "User-Agent": "Studienportal-App"})
        with urllib.request.urlopen(req, timeout=20) as r:
            key = json.loads(r.read()).get("key")
    except Exception:
        return False
    if not key:
        return False
    settings["key"] = winbridge.protect(key)
    _save(settings)
    return True


def _single_instance() -> bool:
    """True, wenn diese die erste laufende App ist (benannter Mutex)."""
    if os.name != "nt":
        return True
    import ctypes
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\StudienportalApp")
    return ctypes.windll.kernel32.GetLastError() != 183   # ERROR_ALREADY_EXISTS


CMD = os.path.join(DATA, "befehl.json")


def _post_command(cmd: dict) -> None:
    os.makedirs(DATA, exist_ok=True)
    with open(CMD, "w", encoding="utf-8") as f:
        json.dump(cmd, f)


def _hotkey_loop(on_press) -> None:
    """Strg+Alt+G (überall): Zwischenablage des Portals öffnen."""
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    if not user32.RegisterHotKey(None, 1, 0x0002 | 0x0001 | 0x4000, ord("G")):   # CONTROL | ALT | NOREPEAT
        return
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
        if msg.message == 0x0312:   # WM_HOTKEY
            on_press()


def _selftest() -> int:
    """Bauprüfung auf Windows: Zwischenablage (Text, Bild, Dateien), DPAPI, Symbolbild, Fenster."""
    from . import winbridge
    ok = True
    log = open(os.path.join(tempfile.gettempdir(), "sp-selftest.txt"), "w", encoding="utf-8")
    print = lambda *a: (log.write(" ".join(str(x) for x in a) + "\n"), log.flush())   # Fenster-App hat keine Konsole
    if os.name == "nt":
        cb = winbridge.Clipboard()
        cb.write("text", "Grüße äöü ✓")
        r = cb.read(); ok &= r == ("text", "Grüße äöü ✓"); print("Text:", r)
        from PIL import Image
        import io
        b = io.BytesIO(); Image.new("RGB", (7, 5), (200, 30, 10)).save(b, "PNG")
        cb.write("image", b.getvalue())
        r = cb.read(); ok &= bool(r) and r[0] == "image" and Image.open(io.BytesIO(r[1])).size == (7, 5); print("Bild:", r and r[0])
        f = os.path.join(tempfile.gettempdir(), "sp-test.txt"); open(f, "w").write("x")
        cb.write("files", [f])
        r = cb.read(); ok &= r == ("files", [f]); print("Dateien:", r)
        ok &= winbridge.unprotect(winbridge.protect("geheim")) == "geheim"; print("DPAPI ok")
        img = _tray_image(); ok &= img is not None; print("Symbol:", img and img.size)
    import webview
    w = webview.create_window(APP_NAME, html="<h1>Studienportal</h1>", width=400, height=300)
    webview.start(lambda: (time.sleep(3), w.destroy()), private_mode=False, storage_path=os.path.join(tempfile.gettempdir(), "sp-selftest"))
    print("Selbsttest", "ok" if ok else "FEHLER", C.VERSION)
    log.close()
    return 0 if ok else 1


def _tray_image():
    try:
        from PIL import Image
        ico = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "web", "icons", "icon.ico")
        return Image.open(ico)
    except Exception:
        return None


def run(argv=None) -> int:
    argv = argv or sys.argv[1:]
    if "--selftest" in argv:
        return _selftest()
    from . import winbridge
    # „Senden an“ aus dem Explorer: Dateien hochladen und wieder beenden (kein Fenster)
    for flag, to_clip in (("--send-clip", True), ("--send-ablage", False)):
        if flag in argv:
            paths = [a for a in argv if a != flag and not a.startswith("--")]
            winbridge.Bridge(_load(), _save, notify, lambda *a: None).send_paths(paths, to_clip)
            time.sleep(2)   # Mitteilung noch zeigen lassen
            return 0
    route = ""
    if "--open" in argv:   # gedankenpalast://kalender (Mitteilung angeklickt)
        i = argv.index("--open")
        route = urllib.parse.urlsplit(argv[i + 1] if i + 1 < len(argv) else "").netloc
    if not _single_instance():
        _post_command({"open": route or "portal"})   # läuft schon (z. B. im Infobereich) → dort zeigen
        return 0
    import webview
    if install_if_needed():
        return 0
    _register_notifications()
    exe = INSTALLED_EXE if getattr(sys, "frozen", False) else os.path.abspath(sys.executable)
    _integrate(exe)
    s = _load()
    api = Api()
    webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True
    webview.settings["ALLOW_DOWNLOADS"] = True
    url = s.get("url")
    start_url = (url + "#/" + route) if url and route else url
    w = webview.create_window(APP_NAME, url=start_url, html=None if url else SETUP_HTML, js_api=api, width=s.get("w", 1440), height=s.get("h", 920),
                              min_size=(820, 560), background_color="#121110", text_select=True, hidden="--background" in argv)
    api.window = w
    updater = Updater()
    state = {"quit": False, "hinted": s.get("trayHinted", False)}
    bridge = winbridge.Bridge(s, _save, notify, None)

    def show(r=""):
        try:
            w.show(); w.restore()
            if r and _load().get("url"):
                w.evaluate_js(f"location.hash = '#/{re.sub(r'[^a-z0-9/-]', '', r)}'")
        except Exception:
            pass
    bridge.show = show

    def quit_app():
        state["quit"] = True
        bridge.stop.set()
        try:
            tray.stop()
        except Exception:
            pass
        w.destroy()

    # Symbol im Infobereich
    tray = None
    try:
        import pystray
        img = _tray_image()
        item, menu = pystray.MenuItem, pystray.Menu

        def toggle(key, default=True, after=None):
            def f(icon, it):
                bridge.set_opt(key, not bridge.opt(key, default))
                if after:
                    after(bridge.opt(key, default))
            return f

        def checked(key, default=True):
            return lambda it: bridge.opt(key, default)

        tray = pystray.Icon(APP_NAME, img, "Gedankenpalast", menu(
            item("Öffnen", lambda: show(), default=True),
            item("Zwischenablage öffnen (Strg+Alt+G)", lambda: show("zwischenablage")),
            menu.SEPARATOR,
            item("Zwischenablage abgleichen", toggle("clipSync"), checked=checked("clipSync")),
            item("Kopierte Dateien mitnehmen (bis 50 MB)", toggle("clipFiles"), checked=checked("clipFiles")),
            item("Ordner „Gedankenpalast“ abgleichen", toggle("folderSync"), checked=checked("folderSync")),
            item("Mitteilungen zu Terminen und Fristen", toggle("alerts"), checked=checked("alerts")),
            item("Mit Windows starten", toggle("autostart", True, lambda on: set_autostart(on, exe)), checked=checked("autostart")),
            menu.SEPARATOR,
            item("Ordner „Gedankenpalast“ öffnen", lambda: os.startfile(bridge.root) if os.path.isdir(bridge.root) else None),
            item("Routine starten", lambda: threading.Thread(target=lambda: bridge.portal and notify("Routine", bridge.portal.action("routine").get("message", "")), daemon=True).start()),
            menu.SEPARATOR,
            item("Beenden", lambda: quit_app()),
        ))
        threading.Thread(target=tray.run, daemon=True).start()
    except Exception as exc:
        print("Infobereich nicht verfügbar:", exc)

    def after_start():
        threading.Thread(target=_hotkey_loop, args=(lambda: show("zwischenablage"),), daemon=True).start()

        def commands():   # Befehle einer zweiten gestarteten App (z. B. Mitteilung angeklickt)
            while not state["quit"]:
                time.sleep(0.5)
                if os.path.exists(CMD):
                    try:
                        with open(CMD, encoding="utf-8") as f:
                            cmd = json.load(f)
                        os.remove(CMD)
                        show(cmd.get("open", ""))
                    except Exception:
                        pass
        threading.Thread(target=commands, daemon=True).start()
        for _ in range(240):   # bis zu 1 Stunde auf die Anmeldung warten
            if state["quit"]:
                return
            cur = _load()
            bridge.s.update({k: cur[k] for k in ("url", "key") if k in cur})
            if _ensure_key(w, bridge.s):
                break
            time.sleep(15)
        bridge.start()
        base = _load().get("url")
        if base:
            updater.check(base, _cookies(w), lambda v: w.evaluate_js(
                f"window.portalToast && window.portalToast('Neue App-Version {v} ist geladen und wird beim Beenden installiert.')"))

    def on_closing():
        try:
            d = _load()
            d["w"], d["h"] = w.width, w.height
            _save({**bridge.s, "w": d["w"], "h": d["h"]})
        except Exception:
            pass
        if tray is not None and not state["quit"]:
            w.hide()   # weiter im Infobereich (Zwischenablage, Ordner, Mitteilungen)
            if not state["hinted"]:
                state["hinted"] = True
                bridge.set_opt("trayHinted", True)
                notify("Gedankenpalast läuft weiter", "Im Infobereich unten rechts – dort auch Beenden.")
            return False
        updater.apply_on_exit()

    w.events.closing += on_closing
    webview.start(after_start, private_mode=False, storage_path=os.path.join(DATA, "webview"))
    return 0
