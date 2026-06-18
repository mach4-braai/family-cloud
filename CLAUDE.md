## Why

Self-hosted Nextcloud on Hetzner Cloud for ~10 extended family members (5 TB total, 500 GB/user). Replaces Google Drive at family scale with German hosting, user isolation, and a cost ceiling under €60/mo. Sole admin is an SRE relocating to Germany; family is non-technical and will reach out via WhatsApp when things break.

Hard constraint: **3-weekends-to-MVP**. Resist scope creep — defer anything not in `PLAN.md` §6.1 (NOT-MVP list).

## What

- `PLAN.md` — architecture decisions, weekend tasks, decisions log, red-flags. Read before any infra change.
- `PREREQUISITES.md` — human-action checklist (tokens, keys, manual state-bucket bootstrap) required before `tofu init`.
- `tofu/` — OpenTofu root + `modules/hetzner-server/`. State backend: Hetzner Object Storage (S3-compat, Ceph-backed).
- `docker/` — `docker-compose.yml` (Nextcloud + Postgres 16 + Caddy), `Caddyfile`, `nextcloud-config/custom.config.php`.
- `scripts/cloud-init.yaml.tpl` — rendered via Tofu `templatefile()`; bootstraps the VPS end-to-end.
- `scripts/backup-db.sh`, `scripts/provision-users.sh` — operational scripts run via Tailscale SSH after Nextcloud is healthy.
- `secrets/family-cloud.enc.yaml` — SOPS+age encrypted. Plaintext secrets must never enter git.

## How

- **Secrets:** SOPS+age only. Provider is `carlpett/sops`; access via `data.sops_file.secrets.data["key"]` (not the deprecated `sops_decrypt`).
- **Provider pins:** `hcloud ~> 1.48`, `aws ~> 5.70`, `sops ~> 1.1`, OpenTofu `~> 1.8`. Do not bump without testing.
- **AWS provider 5.x backend syntax:** use `endpoints { s3 = "..." }` block + `use_path_style = true` (NOT `endpoint` / `force_path_style`). Hetzner Ceph also requires `skip_requesting_account_id` and `skip_s3_checksum` — without them `tofu init` fails with `InvalidAccessKeyId` or checksum errors.
- **Lifecycle:** `prevent_destroy = true` on `hcloud_server`, `hcloud_volume`, Nextcloud data bucket, backup bucket. Never bypass with `-replace` or `-target` shortcuts.
- **Nextcloud + S3 (Hetzner / Ceph) traps:**
  - `'filelocking.enabled' => false` is required — locking deadlocks against S3. Counterintuitive but documented.
  - Group Folders + S3: files >10 MB silently lost when *moved* (not copied) into a Group Folder. Educate users; never auto-move.
  - First login per user takes 1–2 min while Nextcloud scaffolds their storage.
  - `upload_tmp_dir` must point at the 20 GB Cloud Volume — CX22 root disk is only 40 GB and multi-GB uploads will fill it.
- **Nextcloud upgrades** cannot skip major versions (28→29→30, never 28→30). Snapshot the Postgres volume before each bump. Runbook lives at `docs/runbooks/upgrade-nextcloud.md` (post-MVP).
- **Backups are load-bearing:** S3 stores files as `urn:oid:XXXX` — without the Postgres DB they are unrecoverable blobs. Daily `pg_dump` is the DR floor, not a nice-to-have. Test restore quarterly.
- **Test cloud-init on a throwaway CX11** (~€0.007/hr) before applying against the real server. First-boot failure means SSH-and-debug — avoid it.
- **DNS is manual** for MVP — Squarespace has no Tofu provider. After `tofu apply`, paste the server IP into the `stow.mcgeer.dev` A record by hand. Post-MVP: migrate to Route53 or Cloudflare.
- **Cost ceiling:** budget **€60/mo**, not €40 — Hetzner raised prices ~30% in April 2026.
- **Commits:** follow `~/.claude/rules/git-commit.md` (50-char imperative subject, body wraps at 72, code in backticks).
