#!/usr/bin/env bash
#
# deployment_script.sh - set up ONE NEW website on weblinux.
#
# Called by /root/full_deployment.sh for every active line of /root/site.conf:
#     /root/deployment_script.sh SITE_NAME REPO_URL PORT
#
# Rebuilt on 2026-10-07 after the original was lost. It reproduces the layout
# of the existing sites:
#     /srv/SITE_NAME/app     code cloned from GitHub
#     /srv/SITE_NAME/venv    Python virtual environment
#     /etc/systemd/system/gunicorn-SITE_NAME.service
#
# SAFETY: this script only creates NEW sites. If the site folder or its
# service already exists, or the port is already taken, it stops without
# changing anything. It never touches another site.

set -euo pipefail
exec < /dev/null    # never read from the caller's site.conf

# ---------------------------------------------------------------- settings
SRV_ROOT="/srv"
UNIT_DIR="/etc/systemd/system"
RUN_USER="django"
RUN_GROUP="django"
WORKERS=3
MIN_FREE_GB=3            # refuse to deploy with less free disk space than this
RUN_MIGRATE="no"         # "yes" = run: manage.py migrate --noinput
RUN_COLLECTSTATIC="no"   # "yes" = run: manage.py collectstatic --noinput
# --------------------------------------------------------------------------

SITE_NAME="${1:-}"
REPO_URL="${2:-}"
PORT="${3:-}"
PORT="${PORT%$'\r'}"     # drop a Windows line ending, if site.conf has one

SITE_DIR="$SRV_ROOT/$SITE_NAME"
APP_DIR="$SITE_DIR/app"
VENV_DIR="$SITE_DIR/venv"
SERVICE="gunicorn-$SITE_NAME.service"
UNIT_FILE="$UNIT_DIR/$SERVICE"

CREATED_DIR=0
KEEP=0

say()  { echo "[$SITE_NAME] $*"; }
fail() { echo "[$SITE_NAME] ERROR: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  # Only remove a folder that THIS run created, and only if it failed
  # before the service file was written.
  if [[ $code -ne 0 && $CREATED_DIR -eq 1 && $KEEP -eq 0 \
        && -n "$SITE_NAME" && "$SITE_DIR" == "$SRV_ROOT/$SITE_NAME" \
        && -d "$SITE_DIR" ]]; then
    echo "[$SITE_NAME] Deployment failed - removing the half-built folder $SITE_DIR" >&2
    rm -rf --one-file-system -- "$SITE_DIR"
  fi
  exit "$code"
}
trap cleanup EXIT

# ------------------------------------------------------------------ checks
[[ $EUID -eq 0 ]] || fail "run this as root."

[[ -n "$SITE_NAME" && -n "$REPO_URL" && -n "$PORT" ]] \
  || fail "usage: deployment_script.sh SITE_NAME REPO_URL PORT"

[[ "$SITE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
  || fail "site name may only contain letters, digits, '-' and '_'."

[[ "$REPO_URL" =~ ^(https://|git@) ]] \
  || fail "repository address must start with https:// or git@ (got: $REPO_URL)"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) \
  || fail "port must be a number between 1024 and 65535 (got: $PORT)"

id "$RUN_USER" >/dev/null 2>&1 || fail "user '$RUN_USER' does not exist."

[[ ! -e "$SITE_DIR" ]] \
  || fail "$SITE_DIR already exists. This script only sets up NEW sites; nothing was changed."

[[ ! -e "$UNIT_FILE" ]] \
  || fail "$UNIT_FILE already exists. This script only sets up NEW sites; nothing was changed."

# Port already given to another site?
taken_by="$(grep -lE -- ":${PORT}([^0-9]|\$)" "$UNIT_DIR"/gunicorn-*.service 2>/dev/null || true)"
[[ -z "$taken_by" ]] \
  || fail "port $PORT is already used in: $(echo "$taken_by" | tr '\n' ' ')"

# Port already open on this machine?
if command -v ss >/dev/null 2>&1; then
  if ss -Hltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    fail "something is already listening on port $PORT."
  fi
fi

# Enough disk space? (a full disk is what broke the ieread deployment)
free_gb="$(df --output=avail -BG "$SRV_ROOT" | tail -1 | tr -dc '0-9')"
(( free_gb >= MIN_FREE_GB )) \
  || fail "only ${free_gb}G free on $SRV_ROOT, need at least ${MIN_FREE_GB}G. Free up space first."

# -------------------------------------------------------------- deployment
say "Creating $SITE_DIR"
mkdir "$SITE_DIR"        # no -p on purpose: fails if the folder appeared meanwhile
CREATED_DIR=1

say "Downloading code from $REPO_URL"
git clone "$REPO_URL" "$APP_DIR"

# Find the Django project (the folder that holds wsgi.py)
if [[ -f "$APP_DIR/cmms/wsgi.py" ]]; then
  WSGI_MODULE="cmms"
else
  mapfile -t wsgi_files < <(find "$APP_DIR" -mindepth 2 -maxdepth 2 -name wsgi.py)
  [[ ${#wsgi_files[@]} -eq 1 ]] \
    || fail "could not find exactly one wsgi.py in $APP_DIR (found ${#wsgi_files[@]})."
  WSGI_MODULE="$(basename "$(dirname "${wsgi_files[0]}")")"
fi
say "Django project: $WSGI_MODULE"

say "Creating Python environment"
python3 -m venv "$VENV_DIR"

if [[ -f "$APP_DIR/requirements.txt" ]]; then
  say "Installing packages from requirements.txt (this can take several minutes)"
  "$VENV_DIR/bin/pip" install -q --no-cache-dir -r "$APP_DIR/requirements.txt"
else
  say "WARNING: no requirements.txt in the repository - installing nothing from it"
fi

if [[ ! -x "$VENV_DIR/bin/gunicorn" ]]; then
  say "Installing gunicorn"
  "$VENV_DIR/bin/pip" install -q --no-cache-dir gunicorn
fi

chown -R "$RUN_USER:$RUN_GROUP" "$SITE_DIR"

if [[ "$RUN_MIGRATE" == "yes" ]]; then
  say "Running database migrations"
  (cd "$APP_DIR" && runuser -u "$RUN_USER" -- "$VENV_DIR/bin/python" manage.py migrate --noinput)
fi

if [[ "$RUN_COLLECTSTATIC" == "yes" ]]; then
  say "Collecting static files"
  (cd "$APP_DIR" && runuser -u "$RUN_USER" -- "$VENV_DIR/bin/python" manage.py collectstatic --noinput)
fi

say "Writing $UNIT_FILE"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Gunicorn for $SITE_NAME
After=network.target

[Service]
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$APP_DIR
Environment="PATH=$VENV_DIR/bin"
ExecStart=$VENV_DIR/bin/gunicorn --workers $WORKERS --bind 0.0.0.0:$PORT $WSGI_MODULE.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
KEEP=1                   # from here on, keep everything for inspection

say "Starting $SERVICE"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  say "SUCCESS: $SERVICE is running on port $PORT"
  say "Next: on ubuntulin, add this site to sites.csv and run ./deploy_all.sh"
else
  say "The service did not stay running. Last log lines:"
  journalctl -u "$SERVICE" -n 25 --no-pager || true
  fail "$SERVICE failed to start. The folder and service file were kept for inspection."
fi
