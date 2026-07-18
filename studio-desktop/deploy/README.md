# Production deploy — Jac ML Studio

Single-VM, multi-tenant deploy behind Caddy. Files in this dir:

| File | Purpose |
|------|---------|
| `env.example` | Environment/secrets template → `/etc/jac-studio/env` (mode 0600) |
| `studio.service` | systemd unit running `start_prod.sh` |
| `Caddyfile` | TLS reverse proxy, binds the app to loopback |
| `studio-backup.service` / `studio-backup.timer` | daily graph backup |
| `logrotate/jac-studio` | rotation for the audit trail + run logs |

## First install

```bash
# 1. Secrets (see env.example for JWT_SECRET + JAC_SECRET_KEY and rotation notes)
sudo install -D -m 600 -o root -g root deploy/env.example /etc/jac-studio/env
sudo $EDITOR /etc/jac-studio/env          # openssl rand -hex 32 for each secret

# 2. App service
sudo cp deploy/studio.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now studio

# 3. TLS front (edit the domain in the Caddyfile first)
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy

# 4. Daily backups
sudo cp deploy/studio-backup.service deploy/studio-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now studio-backup.timer

# 5. Log rotation
sudo cp deploy/logrotate/jac-studio /etc/logrotate.d/jac-studio
sudo logrotate --debug /etc/logrotate.d/jac-studio   # dry-run: confirm paths
```

## Secrets at rest

Per-user Vast.ai API keys are encrypted on the graph via `crypto.sv.jac` using
`JAC_SECRET_KEY` (falls back to `JWT_SECRET`). Set a dedicated `JAC_SECRET_KEY`
so you can rotate the JWT secret without invalidating stored keys. Rotation
procedure is documented in `env.example`.

## Backup & restore

- Backups: `scripts/backup_graph.sh` tars `.jac/data` → `$JAC_BACKUP_DIR`
  (keeps last 14). Fired daily by `studio-backup.timer`. **Point
  `JAC_BACKUP_DIR` at off-host storage** — a backup on the same disk is not
  disaster recovery.
- Restore: stop the server, then `scripts/restore_graph.sh [tarball]` (newest if
  omitted). The current data dir is moved to `.jac/data.pre-restore-<stamp>`
  first, so the restore is itself reversible.
- Verify the round-trip anytime: `scripts/test_backup_restore.sh` (hermetic,
  uses a temp dir).
