"""TestFlight-Absturzberichte, Bauten und Uploads ausgeben – zur Fehlersuche. Nur lesen."""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from asc_crashes_api import api  # noqa: E402

app = api("apps?filter[bundleId]=de.finnarnold.studienportal").get("data", [])
if not app:
    sys.exit("App nicht gefunden")
aid = app[0]["id"]
for st in ("PROCESSING", "FAILED", "INVALID"):
    for b in api(f"builds?filter[app]={aid}&filter[processingState]={st}&limit=10").get("data", []):
        print("Build", b["attributes"].get("version"), st, b["attributes"].get("uploadedDate"))
up = api(f"apps/{aid}/buildUploads?limit=6&sort=-uploadedDate")
for u in up.get("data", []):
    print("Upload", json.dumps(u.get("attributes"), ensure_ascii=False)[:900])
for b in api(f"builds?filter[app]={aid}&sort=-uploadedDate&limit=5&include=preReleaseVersion").get("data", []):
    a = b["attributes"]
    print("Build", a.get("version"), a.get("processingState"), a.get("uploadedDate"), "abgelaufen" if a.get("expired") else "")
subs = api(f"apps/{aid}/betaFeedbackCrashSubmissions?limit=10&sort=-createdDate").get("data", [])
print(f"{len(subs)} Absturzberichte")
for s in subs:
    a = s["attributes"]
    print("=" * 100)
    print({k: a.get(k) for k in ("createdDate", "comment", "deviceModel", "osVersion", "appPlatform", "deviceFamily", "buildBundleId")})
    log = api(f"betaFeedbackCrashSubmissions/{s['id']}/crashLog").get("data") or {}
    text = (log.get("attributes") or {}).get("logText") or ""
    lines = text.splitlines()
    # Kopf, Ausnahme und der abgestürzte Thread genügen
    keep, crashed = [], False
    for i, l in enumerate(lines):
        if i < 60 or "Exception" in l or "Termination" in l or "Crashed" in l or crashed:
            keep.append(l)
        if "Crashed:" in l:
            crashed = True
        elif crashed and not l.strip():
            crashed = False
    print("\n".join(keep[:260]))
fb = api(f"apps/{aid}/betaFeedbackScreenshotSubmissions?limit=5&sort=-createdDate").get("data", [])
for f in fb:
    print("Feedback:", {k: f["attributes"].get(k) for k in ("createdDate", "comment", "deviceModel", "osVersion")})
