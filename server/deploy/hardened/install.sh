#!/usr/bin/env bash
# The hardened install (see README.md here): the `food` binary root-owned in /usr/local/bin, the
# service as a dedicated system user under a locked-down system unit, its SQLCipher key sealed
# to this machine's TPM as a systemd credential, /etc/plate/config.toml so the login user's CLI
# finds the socket, optionally a `tailscale serve` route, and optionally the Health-refresh
# timer. Run as root after `cargo build --release`, from anywhere:
#
#   sudo ./deploy/hardened/install.sh
#
# Safe to run again: the key is created once, and the data is never moved or rewritten.
set -euo pipefail

# Settings. The defaults are one machine's; set any of them in the environment for yours.
READER=${READER:-${SUDO_USER:-}}                 # the login user whose CLI (and agents) use the service
SERVICE_USER=${SERVICE_USER:-health}             # the dedicated system user the service runs as
DATA=${DATA:-/mnt/ssd/personal-health/food}      # the database directory (mode 700, SERVICE_USER's)
REQUIRE_MOUNT=${REQUIRE_MOUNT-/mnt/ssd}          # refuse unless this is mounted ("" to skip the check)
TAILSCALE_PORT=${TAILSCALE_PORT-8445}            # the tailnet HTTPS port ("" to skip tailscale serve)
HEALTH_TIMER=${HEALTH_TIMER:-auto}               # yes, no, or auto: only if a `health` CLI is installed

CRED=/etc/credstore.encrypted/personal-food-key.cred
UNIT=/etc/systemd/system/personal-food.service
SOCKET=/run/personal-food/food.sock
CONFIG=/etc/plate/config.toml

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$READER" ] || { echo "set READER to the login user who runs the food CLI (or run through sudo)" >&2; exit 1; }
cd "$(dirname "$0")/../.."
[ -x target/release/food ] || { echo "run cargo build --release first" >&2; exit 1; }
[ -z "$REQUIRE_MOUNT" ] || mountpoint -q "$REQUIRE_MOUNT" || { echo "$REQUIRE_MOUNT isn't mounted" >&2; exit 1; }
systemd-creds has-tpm2 >/dev/null || { echo "no usable TPM2" >&2; exit 1; }
reader_uid=$(id -u "$READER")
reader_home=$(getent passwd "$READER" | cut -d: -f6)
user_units=$reader_home/.config/systemd/user
as_reader() { runuser -u "$READER" -- env XDG_RUNTIME_DIR=/run/user/$reader_uid "$@"; }

id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"

# The settings the CLI needs (the socket) and the service reads. No secrets: world-readable.
install -d -o root -g root -m 755 /etc/plate
cat > "$CONFIG.new" <<EOF
# Written by deploy/hardened/install.sh; the unit's FOOD_* variables win over it.
data_dir = $DATA
socket = $SOCKET
socket_uids = $reader_uid
listen = 127.0.0.1:18792
encryption = systemd-credential
credential = food-key
EOF
chmod 644 "$CONFIG.new"
mv "$CONFIG.new" "$CONFIG"

# Root owns the binary, because $READER could otherwise replace it.
install -o root -g root -m 755 target/release/food /usr/local/bin/food
parent=$(dirname "$DATA")
[ -d "$parent" ] || install -d -o root -g root -m 755 "$parent"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$DATA"
install -d -o root -g root -m 700 /etc/credstore.encrypted

if [ ! -f "$CRED" ]; then
    [ ! -e "$DATA/food.db" ] || { echo "FAIL: $DATA/food.db exists but its key doesn't; move it away first" >&2; exit 1; }
    key=$(mktemp)
    trap 'shred -u "$key" 2>/dev/null || true' EXIT
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$key"
    # Both the host key and the TPM are needed to open it: a copied disk alone can't.
    systemd-creds encrypt --with-key=host+tpm2 --name=food-key "$key" "$CRED"
    shred -u "$key"
    trap - EXIT
    echo "created the database key $CRED"
fi

sed -e "s/@READER_UID@/$reader_uid/" -e "s|@DATA@|$DATA|g" -e "s/@SERVICE_USER@/$SERVICE_USER/g" \
    deploy/hardened/personal-food.service > "$UNIT"
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable personal-food.service
systemctl restart personal-food.service
for _ in $(seq 1 30); do [ -S "$SOCKET" ] && break; sleep 1; done

# Check it from $READER's side.
version=$(as_reader /usr/local/bin/food query "SELECT value FROM meta WHERE key = 'version'" | tr -dc '0-9')
echo "the service answers $READER at version ${version:-0}"
curl -sf http://127.0.0.1:18792/v1/ping | grep -q '"ok":true' || { echo "FAIL: no answer on 127.0.0.1:18792" >&2; exit 1; }
if head -c 16 "$DATA/food.db" | grep -q "SQLite format 3"; then echo "FAIL: database is not encrypted" >&2; exit 1; fi
if as_reader ls "$DATA" >/dev/null 2>&1; then echo "FAIL: $READER can read $DATA" >&2; exit 1; fi

# The tailnet route. Leaves every other serve entry alone.
if [ -n "$TAILSCALE_PORT" ] && ! tailscale serve status 2>/dev/null | grep -q ":$TAILSCALE_PORT"; then
    tailscale serve --bg --https="$TAILSCALE_PORT" http://127.0.0.1:18792
fi

# Health context: $READER reads Health through its `health` CLI and pushes it every 30 minutes.
if [ "$HEALTH_TIMER" = yes ] || { [ "$HEALTH_TIMER" = auto ] && as_reader sh -c 'command -v health || [ -x /usr/local/bin/health ]' >/dev/null; }; then
    install -d -o "$READER" -g "$READER" "$user_units"
    install -o "$READER" -g "$READER" -m 644 deploy/hardened/personal-food-health.service deploy/hardened/personal-food-health.timer "$user_units/"
    as_reader systemctl --user daemon-reload
    as_reader systemctl --user enable --now personal-food-health.timer
    echo "the Health refresh timer runs as $READER"
fi
echo "installed: database $DATA/food.db (encrypted, key sealed to this machine), HTTP 127.0.0.1:18792${TAILSCALE_PORT:+, tailnet :$TAILSCALE_PORT}"
