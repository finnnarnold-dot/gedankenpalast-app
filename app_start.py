"""Startpunkt für die Windows-App (Studienportal-App.exe): eigenes Fenster statt Browser-Tab."""
import sys

from portal.desktop import run

if __name__ == "__main__":
    sys.exit(run())
