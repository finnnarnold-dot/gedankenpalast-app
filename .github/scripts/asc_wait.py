"""Nach dem Upload: warten, bis Apple den Build verarbeitet hat (TestFlight). Schlägt fehl, wenn er nicht ankommt –
dann ist das Update NICHT da (z. B. weil Apple den Build verworfen hat; Grund steht in Apples Mail)."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from asc_crashes_api import api  # noqa: E402

num = os.environ["BUILD_NUMBER"]
app = api("apps?filter[bundleId]=de.finnarnold.studienportal").get("data", [])
aid = app[0]["id"]
for i in range(30):
    data = api(f"builds?filter[app]={aid}&filter[version]={num}&limit=1").get("data", [])
    if data:
        st = data[0]["attributes"].get("processingState")
        print(f"Build {num}: {st}")
        if st == "VALID":
            print("In TestFlight verfügbar.")
            sys.exit(0)
        if st in ("FAILED", "INVALID"):
            sys.exit(f"Apple hat Build {num} abgelehnt ({st}) – Grund in der Mail von App Store Connect.")
    else:
        print(f"{i + 1} Min.: Build {num} bei Apple noch nicht angekommen")
    time.sleep(60)
sys.exit(f"Build {num} ist nach 30 Minuten nicht in TestFlight – Apple hat ihn vermutlich verworfen (Mail von App Store Connect prüfen).")
