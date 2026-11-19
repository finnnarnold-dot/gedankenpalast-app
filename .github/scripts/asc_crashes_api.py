"""Zugriff auf die App-Store-Connect-Schnittstelle (nur lesen)."""
import json, os, sys, time, urllib.error, urllib.request
import jwt

TMP = os.environ["RUNNER_TEMP"]


def token():
    key = open(os.path.join(TMP, "AuthKey_" + os.environ["ASC_KEY_ID"] + ".p8")).read()
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 900,
                       "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def api(path):
    url = path if path.startswith("https://") else "https://api.appstoreconnect.apple.com/v1/" + path
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        print(f"Apple: {e.code} bei {url.split('?')[0]}: {e.read()[:400].decode(errors='replace')}")
        return {}


