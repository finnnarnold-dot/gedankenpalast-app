# PyInstaller-Bauplan für Studienportal-App.exe (Windows-App mit eigenem Fenster, WebView2)
# Bauen: pyinstaller studienportal-app.spec
import os
from PyInstaller.utils.hooks import collect_submodules, collect_data_files
a = Analysis(
    ['app_start.py'],
    datas=[('web/icons', 'web/icons')] + collect_data_files('webview'),
    hiddenimports=collect_submodules('webview.platforms') + ['clr', 'pystray._win32', 'PIL.Image', 'PIL.BmpImagePlugin', 'PIL.PngImagePlugin', 'PIL.IcoImagePlugin'],
    excludes=['tkinter', 'pptx', 'pypdf', 'playwright'],
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, a.binaries, a.datas, [],
    name='Studienportal-App',
    icon='web/icons/icon.ico' if os.path.exists('web/icons/icon.ico') else None,
    console=False,
    upx=False,
)
