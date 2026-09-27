#!/usr/bin/env bash
# Moves Hearts Scorecard onto the Home Board PocketBase (bkhomevps). Safe to run again.
# Run ON the VPS as root:
#   curl -fsSL https://raw.githubusercontent.com/crimdow/hearts/main/hearts-pb-setup.sh | tr -d '\r' | bash
#
# What it does:
#   1. Creates the hearts_* collections and the editor/viewer logins in PocketBase
#   2. Copies players, finished games and the live game over from Supabase (if it's still reachable)
#   3. Points hearts.jermins.com/api at PocketBase in Caddy, then pulls the latest app from GitHub
set -e

PB_BIN=${PB_BIN:-/opt/pocketbase/pocketbase}
PB_DIR=${PB_DIR:-/srv/home-board/pb_data}
PB_URL=${PB_URL:-http://127.0.0.1:8090}
RUN_AS=${RUN_AS:-homeboard}
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
SITE=${SITE:-/var/www/hearts}
SKIP_CADDY=${SKIP_CADDY:-}

ask() { # ask "prompt" var  (reads from the keyboard even when piped through curl)
  local v; read -r -s -p "$1" v </dev/tty; echo >/dev/tty; printf -v "$2" '%s' "$v"
}
[ -n "$EDITOR_CODE" ] || ask "Editor code (3 digits): " EDITOR_CODE
[ -n "$VIEWER_CODE" ] || ask "Viewer code (3 digits): " VIEWER_CODE

# A throwaway admin account just for this run, removed again at the end
SU_EMAIL="hearts-setup-$(date +%s)@example.com"
SU_PASS=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
as_pb() { if [ -n "$RUN_AS" ] && id "$RUN_AS" >/dev/null 2>&1; then sudo -u "$RUN_AS" "$@"; else "$@"; fi; }
cleanup() { as_pb "$PB_BIN" superuser delete "$SU_EMAIL" --dir "$PB_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "== Signing in to PocketBase"
as_pb "$PB_BIN" superuser upsert "$SU_EMAIL" "$SU_PASS" --dir "$PB_DIR" >/dev/null

export PB_URL SU_EMAIL SU_PASS EDITOR_CODE VIEWER_CODE
python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

PB = os.environ["PB_URL"]
SB = "https://ejfmjwlsdhkwhihqrssa.supabase.co"
SB_KEY = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVqZm1qd2xzZGhrd2hpaHFyc3NhIiwicm9sZSI6"
          "ImFub24iLCJpYXQiOjE3OTAyOTI2NjMsImV4cCI6MjEwNTg2ODY2M30.xDgoEOmVADhixG3mQTlK6PPR_0zO2kSzPuTTtQ1zLoQ")

def call(method, url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, raw.decode(errors="replace")
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e)

st, auth = call("POST", PB + "/api/collections/_superusers/auth-with-password",
                {"identity": os.environ["SU_EMAIL"], "password": os.environ["SU_PASS"]})
if st != 200: sys.exit(f"Couldn't sign in to PocketBase ({st}): {auth}")
H = {"Authorization": auth["token"]}

AUTHED = '@request.auth.collectionName = "hearts_users"'
EDITOR = AUTHED + ' && @request.auth.role = "editor"'
def base(name, fields):
    return {"name": name, "type": "base", "fields": [{"name": "key", "type": "text", "required": True, "max": 100}] + fields,
            "indexes": [f"CREATE UNIQUE INDEX `idx_{name}_key` ON `{name}` (`key`)"],
            "listRule": AUTHED, "viewRule": AUTHED, "createRule": EDITOR, "updateRule": EDITOR, "deleteRule": EDITOR}

COLLECTIONS = [
    {"name": "hearts_users", "type": "auth",
     "fields": [{"name": "role", "type": "select", "values": ["editor", "viewer"], "maxSelect": 1, "required": True}],
     "passwordAuth": {"enabled": True, "identityFields": ["email"]},
     "listRule": "id = @request.auth.id", "viewRule": "id = @request.auth.id",
     "createRule": None, "updateRule": None, "deleteRule": None, "authRule": ""},
    base("hearts_people", [{"name": "name", "type": "text", "required": True}, {"name": "added_at", "type": "text"}]),
    base("hearts_games", [{"name": "ended_at", "type": "text"}, {"name": "early", "type": "bool"}, {"name": "hands", "type": "number"},
                          {"name": "players", "type": "json"}, {"name": "finals", "type": "json"},
                          {"name": "winners", "type": "json"}, {"name": "moons", "type": "json"}]),
    base("hearts_live", [{"name": "state", "type": "json"}, {"name": "updated_by", "type": "text"}, {"name": "updated_at", "type": "text"}]),
]

print("== Creating collections")
for c in COLLECTIONS:
    st, existing = call("GET", f"{PB}/api/collections/{c['name']}", headers=H)
    if st == 200:
        # keep the fields, refresh the rules
        rules = {k: c[k] for k in ("listRule", "viewRule", "createRule", "updateRule", "deleteRule") if k in c}
        st, res = call("PATCH", f"{PB}/api/collections/{c['name']}", rules, H)
        print(f"   {c['name']}: already there, rules refreshed" if st == 200 else f"   {c['name']}: couldn't update rules ({st}) {res}")
        continue
    st, res = call("POST", f"{PB}/api/collections", c, H)
    if st != 200: sys.exit(f"Couldn't create {c['name']} ({st}): {res}")
    print(f"   {c['name']}: created")

print("== Setting up the editor and viewer logins")
for role, code in (("editor", os.environ["EDITOR_CODE"]), ("viewer", os.environ["VIEWER_CODE"])):
    email, pw = f"{role}@hearts.jermins.com", f"hearts-{code}"
    st, found = call("GET", f"{PB}/api/collections/hearts_users/records?filter=" + urllib.request.quote(f'email="{email}"'), headers=H)
    body = {"email": email, "password": pw, "passwordConfirm": pw, "role": role, "verified": True}
    if st == 200 and found["items"]:
        st, res = call("PATCH", f"{PB}/api/collections/hearts_users/records/{found['items'][0]['id']}", body, H)
    else:
        st, res = call("POST", f"{PB}/api/collections/hearts_users/records", body, H)
    if st != 200: sys.exit(f"Couldn't save the {role} login ({st}): {res}")
    print(f"   {role} login ready")

def upsert(col, key, data):
    st, found = call("GET", f"{PB}/api/collections/{col}/records?filter=" + urllib.request.quote(f'key="{key}"'), headers=H)
    if st == 200 and found["items"]:
        return call("PATCH", f"{PB}/api/collections/{col}/records/{found['items'][0]['id']}", data, H)
    return call("POST", f"{PB}/api/collections/{col}/records", {"key": key, **data}, H)

print("== Copying data over from Supabase")
st, tok = call("POST", SB + "/auth/v1/token?grant_type=password",
               {"email": "editor@hearts.jermins.com", "password": "hearts-" + os.environ["EDITOR_CODE"]}, {"apikey": SB_KEY})
if st != 200:
    print(f"   Supabase didn't answer ({st}); skipping the copy. Your PocketBase setup is still done.")
else:
    SH = {"apikey": SB_KEY, "Authorization": "Bearer " + tok["access_token"]}
    counts = {}
    for table, col, fields in (("people", "hearts_people", ["name", "added_at"]),
                               ("games", "hearts_games", ["ended_at", "early", "hands", "players", "finals", "winners", "moons"]),
                               ("live_game", "hearts_live", ["state", "updated_by", "updated_at"])):
        st, rows = call("GET", f"{SB}/rest/v1/{table}?select=*", headers=SH)
        if st != 200:
            print(f"   {table}: couldn't read ({st}) {rows}"); continue
        n = 0
        for r in rows:
            s, res = upsert(col, str(r["id"]), {f: r.get(f) for f in fields})
            if s == 200: n += 1
            else: print(f"   {table} {r['id']}: {s} {res}")
        counts[table] = n
    print("   copied " + ", ".join(f"{v} {k}" for k, v in counts.items()))
print("== PocketBase is ready")
PY

if [ -z "$SKIP_CADDY" ]; then
  echo "== Pointing hearts.jermins.com/api at PocketBase"
  cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CADDYFILE" "$SITE" <<'PY'
import re, sys
path, site = sys.argv[1], sys.argv[2]
text = open(path).read()
block = f"""hearts.jermins.com {{
	encode gzip
	@private path /.git* /.git/* /supabase/* /README.md /*.sh
	respond @private 404
	handle /api/* {{
		reverse_proxy 127.0.0.1:8090
	}}
	handle {{
		root * {site}
		@fresh path / /index.html /manifest.webmanifest
		header @fresh Cache-Control "no-cache"
		file_server
	}}
}}
"""
m = re.search(r"^hearts\.jermins\.com\s*\{", text, re.M)
if m:
    depth, i = 0, m.end() - 1
    while i < len(text):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    text = text[:m.start()] + block + text[i + 2:]
else:
    text = text.rstrip() + "\n\n" + block
open(path, "w").write(text)
PY
  caddy validate --config "$CADDYFILE" --adapter caddyfile
  systemctl reload caddy
  echo "== Pulling the latest app"
  git -C "$SITE" pull --ff-only
fi
echo
echo "Done. Open https://hearts.jermins.com and sign in with your codes."
