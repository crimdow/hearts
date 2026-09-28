#!/usr/bin/env bash
# Moves Hearts Scorecard onto the Home Board PocketBase (bkhomevps). Safe to run again.
# Run ON the VPS as root:
#   curl -fsSL https://raw.githubusercontent.com/crimdow/hearts/main/hearts-pb-setup.sh | tr -d '\r' | bash
#
# What it does:
#   1. Creates the hearts_* collections in PocketBase and removes the old shared code logins
#   2. Optionally creates a personal login (asks for a username, password and role)
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
askv() { local v; read -r -p "$1" v </dev/tty; printf -v "$2" '%s' "$v"; }
if [ -z "$NEW_EMAIL" ] && [ -z "$NO_NEW_USER" ]; then
  askv "Add a login? Username (or just press Enter to skip): " NEW_EMAIL
fi
if [ -n "$NEW_EMAIL" ]; then
  [ -n "$NEW_ROLE" ] || askv "Role for $NEW_EMAIL - editor or viewer: " NEW_ROLE
  [ -n "$NEW_PASS" ] || ask "Password (8+ characters): " NEW_PASS
fi

# A throwaway admin account just for this run, removed again at the end
SU_EMAIL="hearts-setup-$(date +%s)@example.com"
SU_PASS=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
as_pb() { if [ -n "$RUN_AS" ] && id "$RUN_AS" >/dev/null 2>&1; then sudo -u "$RUN_AS" "$@"; else "$@"; fi; }
cleanup() { as_pb "$PB_BIN" superuser delete "$SU_EMAIL" --dir "$PB_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "== Signing in to PocketBase"
as_pb "$PB_BIN" superuser upsert "$SU_EMAIL" "$SU_PASS" --dir "$PB_DIR" >/dev/null

export PB_URL SU_EMAIL SU_PASS NEW_EMAIL NEW_ROLE NEW_PASS
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
     "fields": [{"name": "role", "type": "select", "values": ["editor", "viewer"], "maxSelect": 1, "required": True},
              {"name": "username", "type": "text", "required": False, "max": 40}],
     "indexes": ["CREATE UNIQUE INDEX `idx_hearts_username` ON `hearts_users` (`username` COLLATE NOCASE) WHERE `username` != ''"],
     "passwordAuth": {"enabled": True, "identityFields": ["username"]},
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
        # keep the data, refresh the rules (and move the logins over to usernames)
        rules = {k: c[k] for k in ("listRule", "viewRule", "createRule", "updateRule", "deleteRule") if k in c}
        if c["type"] == "auth":
            fields = existing["fields"]
            for f in fields:
                if f["name"] == "email": f["required"] = False
            if not any(f["name"] == "username" for f in fields):
                fields.append({"name": "username", "type": "text", "required": False, "max": 40})
            idx = [i for i in existing.get("indexes", []) if "idx_hearts_username" not in i] + c["indexes"]
            rules.update({"fields": fields, "indexes": idx, "passwordAuth": c["passwordAuth"]})
        st, res = call("PATCH", f"{PB}/api/collections/{c['name']}", rules, H)
        print(f"   {c['name']}: already there, rules refreshed" if st == 200 else f"   {c['name']}: couldn't update rules ({st}) {res}")
        continue
    st, res = call("POST", f"{PB}/api/collections", c, H)
    if st != 200: sys.exit(f"Couldn't create {c['name']} ({st}): {res}")
    print(f"   {c['name']}: created")

print("== Logins")
def q(f): return urllib.request.quote(f)
# the old shared code logins are retired in favour of personal ones
for old in ("editor@hearts.jermins.com", "viewer@hearts.jermins.com"):
    st, found = call("GET", f"{PB}/api/collections/hearts_users/records?filter=" + q(f'email="{old}"'), headers=H)
    if st == 200 and found["items"]:
        call("DELETE", f"{PB}/api/collections/hearts_users/records/{found['items'][0]['id']}", headers=H)
        print(f"   removed the shared login {old}")
email = os.environ.get("NEW_EMAIL", "").strip()  # the username
if email:
    role = os.environ.get("NEW_ROLE", "").strip().lower()
    if role not in ("editor", "viewer"): sys.exit("Role must be editor or viewer.")
    pw = os.environ.get("NEW_PASS", "")
    if len(pw) < 8: sys.exit("The password needs at least 8 characters.")
    body = {"username": email, "password": pw, "passwordConfirm": pw, "role": role}
    st, found = call("GET", f"{PB}/api/collections/hearts_users/records?filter=" + q(f'username="{email}"'), headers=H)
    if st == 200 and found["items"]:
        st, res = call("PATCH", f"{PB}/api/collections/hearts_users/records/{found['items'][0]['id']}", body, H)
    else:
        st, res = call("POST", f"{PB}/api/collections/hearts_users/records", body, H)
    if st != 200: sys.exit(f"Couldn't save the login for {email} ({st}): {res}")
    print(f"   {email} can sign in as {role}")
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
echo "Done. Open https://hearts.jermins.com and sign in with your username and password."
