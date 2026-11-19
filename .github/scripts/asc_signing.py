"""Unterschreiben für TestFlight ohne Mac und ohne Apples Automatik (kommt mit App-Gruppe/iCloud nicht zurecht).

setup:   erzeugt Schlüssel + Zertifikat (Apple Distribution) und App-Store-Profile für App und Widgets über die
         App-Store-Connect-Schnittstelle, legt sie in einen eigenen Schlüsselbund bzw. den Profil-Ordner.
cleanup: widerruft Zertifikat und löscht Profile wieder (bereits hochgeladene Builds bleiben gültig).
Geheimnisse kommen aus Umgebungsvariablen und werden nie ausgegeben.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request
import jwt

TMP = os.environ["RUNNER_TEMP"]
STATE = os.path.join(TMP, "signing.json")
BUNDLES = {"de.finnarnold.studienportal": "Studienportal", "de.finnarnold.studienportal.widgets": "Studienportal Widgets",
           "de.finnarnold.studienportal.share": "Studienportal Teilen"}


def token():
    key = open(os.path.join(TMP, "AuthKey_" + os.environ["ASC_KEY_ID"] + ".p8")).read()
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 900,
                       "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def api(path, body=None, method=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/" + path,
                                 data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Apple lehnt {method or ('POST' if body else 'GET')} {path.split('?')[0]} ab: {e.code} {e.read()[:500].decode(errors='replace')}")


def sh(*cmd, quiet=False):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"Befehl fehlgeschlagen: {cmd[0]} {cmd[1] if len(cmd) > 1 else ''}: {r.stderr[-400:]}")
    return r.stdout


def setup():
    run = os.environ.get("GITHUB_RUN_NUMBER", "0")
    keyf, csrf = os.path.join(TMP, "dist.key"), os.path.join(TMP, "dist.csr")
    sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyf, "-out", csrf, "-subj", "/CN=Gedankenpalast CI")
    # alte, von früheren Läufen übrig gebliebene CI-Zertifikate entfernen (Apple erlaubt nur wenige)
    for c in api("certificates?limit=200&filter[certificateType]=DISTRIBUTION").get("data", []):
        if "Gedankenpalast CI" in (c["attributes"].get("name") or "") or "Gedankenpalast CI" in (c["attributes"].get("displayName") or ""):
            api("certificates/" + c["id"], method="DELETE")
    cert = api("certificates", {"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": open(csrf).read()}}})["data"]
    state = {"cert": cert["id"], "profiles": []}
    json.dump(state, open(STATE, "w"))
    der = os.path.join(TMP, "dist.cer"); pem = os.path.join(TMP, "dist.pem"); p12 = os.path.join(TMP, "dist.p12")
    open(der, "wb").write(base64.b64decode(cert["attributes"]["certificateContent"]))
    sh("openssl", "x509", "-inform", "DER", "-in", der, "-out", pem)
    pw = "ci"
    try:
        sh("openssl", "pkcs12", "-export", "-legacy", "-inkey", keyf, "-in", pem, "-out", p12, "-passout", "pass:" + pw)
    except SystemExit:
        sh("openssl", "pkcs12", "-export", "-inkey", keyf, "-in", pem, "-out", p12, "-passout", "pass:" + pw)
    kc = os.path.join(TMP, "build.keychain-db")
    sh("security", "create-keychain", "-p", pw, kc)
    sh("security", "set-keychain-settings", "-lut", "3600", kc)
    sh("security", "unlock-keychain", "-p", pw, kc)
    sh("security", "import", p12, "-k", kc, "-P", pw, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", pw, kc)
    existing = sh("security", "list-keychains", "-d", "user").split()
    sh("security", "list-keychains", "-d", "user", "-s", kc, *[x.strip('"') for x in existing])
    # Profile
    ids = {b["attributes"]["identifier"]: b["id"] for b in api("bundleIds?limit=200")["data"]}
    # Push-Mitteilungen für die App-ID einschalten (einmalig; Finn hat dafür einen APNs-Schlüssel angelegt)
    try:
        b = api("bundleIds?filter[identifier]=de.finnarnold.studienportal&include=bundleIdCapabilities")
        have_caps = [c["attributes"].get("capabilityType") for c in b.get("included", [])]
        if "PUSH_NOTIFICATIONS" not in have_caps:
            api("bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities", "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
                                                  "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": ids["de.finnarnold.studienportal"]}}}}})
            print("Push-Mitteilungen für die App-ID eingeschaltet")
        else:
            print("Push-Mitteilungen sind für die App-ID eingeschaltet")
    except SystemExit as e:
        print("Push nicht einschaltbar:", e)
    dirs = [os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
            os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")]
    for d in dirs:
        os.makedirs(d, exist_ok=True)
    names = {}
    caps = {}
    for ident, label in BUNDLES.items():
        if ident not in ids:   # neue Erweiterung: Kennung einmalig registrieren
            ids[ident] = api("bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": ident, "name": label, "platform": "IOS"}}})["data"]["id"]
            print("Registriert:", ident)
    for ident in BUNDLES:
        name = f"Gedankenpalast CI {ident.split('.')[-1]} {run}"
        prof = api("profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                                         "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": ids[ident]}},
                                                           "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
        state["profiles"].append(prof["id"]); json.dump(state, open(STATE, "w"))
        content = base64.b64decode(prof["attributes"]["profileContent"])
        for d in dirs:
            open(os.path.join(d, prof["attributes"]["uuid"] + ".mobileprovision"), "wb").write(content)
        names[ident] = name
        # Berechtigungen aus dem Profil lesen: App-Gruppen und iCloud-Container so übernehmen, wie sie bei Apple heißen
        import plistlib
        raw = subprocess.run(["security", "cms", "-D", "-i", "/dev/stdin"], input=content, capture_output=True).stdout
        try:
            ent = plistlib.loads(raw).get("Entitlements", {})
        except Exception:
            ent = {}
        groups = [g for g in ent.get("com.apple.security.application-groups", []) if "*" not in g]
        icloud = [c for c in ent.get("com.apple.developer.icloud-container-identifiers", []) if "*" not in c]
        push = "aps-environment" in ent
        print(f"Profil {ident}: App-Gruppen {groups or 'keine'}, iCloud-Container {icloud or 'keine'}, Push {'ja' if push else 'nein'}")
        caps[ident] = {"groups": groups, "icloud": icloud, "push": push}
    json.dump(names, open(os.path.join(TMP, "profiles.json"), "w"))
    json.dump(caps, open(os.path.join(TMP, "caps.json"), "w"))
    if not caps["de.finnarnold.studienportal"]["icloud"]:
        print("Hinweis: Bei Apple sind App-Gruppe/iCloud-Container der App-ID noch nicht zugeordnet – "
              "die App wird ohne diese Funktionen gebaut (Anleitung: docs/IOS-APP.md, Abschnitt iCloud).")
    os.remove(keyf)


def cleanup():
    if not os.path.exists(STATE):
        return
    state = json.load(open(STATE))
    for pid in state.get("profiles", []):
        try: api("profiles/" + pid, method="DELETE")
        except SystemExit as e: print(e)
    if state.get("cert"):
        try: api("certificates/" + state["cert"], method="DELETE")
        except SystemExit as e: print(e)
    print("Zertifikat und Profile wieder entfernt")


if __name__ == "__main__":
    {"setup": setup, "cleanup": cleanup}[sys.argv[1]]()
