# Hardened install (optional, Linux with systemd and a TPM)

The normal setup (`food init`, then `food serve` as your own user) keeps the database key in a
file next to the database. That protects a copied backup or a stolen disk image of the database,
but anything running as your user can read both. This directory is a stricter, optional mode:

- **A dedicated system user** (default `health`) runs the service. Your login user can't read the
  database directory (mode 700, owned by the service user); it reaches the data only through the
  CLI socket, which answers your uid and root (checked with `SO_PEERCRED`).
- **A TPM-sealed key.** `install.sh` makes a random 256-bit key once and seals it with
  `systemd-creds encrypt --with-key=host+tpm2` into `/etc/credstore.encrypted/`. The unit loads it
  with `LoadCredentialEncrypted=`, so it exists in plaintext only inside the running service. A
  copy of the disk can't open the database without this machine's TPM.
- **A locked-down unit.** `personal-food.service` uses `ProtectSystem=strict`, `ProtectHome`,
  `PrivateDevices`, `NoNewPrivileges`, an empty capability set, a system call filter, a 1 GB
  memory cap, and so on. Outgoing network stays open for Open Food Facts.
- **A root-owned binary** in `/usr/local/bin/food`, so the login user can't swap it.
- `/etc/plate/config.toml` (no secrets) tells the CLI where the socket is.
- Optionally a `tailscale serve` route (HTTPS on the tailnet, port 8445 by default) and a user
  timer that runs `food health refresh` every 30 minutes, if a separate Personal Health server's
  `health` CLI is installed.

The trade-off: you can't open the database file yourself, even as root, without going through
`systemd-creds` on this same machine. If the TPM is cleared, or the disk moves to another
machine, the database can't be decrypted. Make regular backups with `food export` (it runs
through the socket and doesn't need the key); `food import` restores them into any Plate server.

## Install

```
cargo build --release
sudo ./deploy/hardened/install.sh
```

It reads its settings from the environment; the defaults at the top of the script are one
machine's, so set yours:

| Variable | Meaning |
|---|---|
| `READER` | The login user who runs the CLI. Default: the user who ran `sudo`. |
| `SERVICE_USER` | The dedicated system user (created if missing). |
| `DATA` | The database directory. |
| `REQUIRE_MOUNT` | Refuse to install unless this path is a mount point; `""` skips the check. |
| `TAILSCALE_PORT` | The tailnet HTTPS port for `tailscale serve`; `""` skips it. |
| `HEALTH_TIMER` | `yes`, `no`, or `auto` (only if a `health` CLI exists). |

For example:

```
sudo READER=alice SERVICE_USER=plate DATA=/var/lib/plate REQUIRE_MOUNT= ./deploy/hardened/install.sh
```

Running it again upgrades the binary and the unit and restarts the service; the key and the
data are kept. It refuses to make a new key when a database already exists without one.

Afterwards, as the login user: `food token new` for the app, and `food seed-usda` once.
