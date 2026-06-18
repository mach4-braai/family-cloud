# Progress Log

> Session-durable state for `family-cloud`. If you (or a fresh Claude session)
> need to pick up where we left off, read this file first, then `PLAN.md §0`
> and `PREREQUISITES.md`.

**Last updated:** 2026-04-23

---

## End Goal

Ship a self-hosted Nextcloud instance on Hetzner Cloud for ~10 family users
(500 GB quota each, 5 TB total), fully provisioned from `tofu apply`.
Cattle, not pets — cloud-init bootstraps everything, secrets via SOPS+age in
git. Public HTTPS at `stow.mcgeer.dev`; admin SSH via Tailscale only.

**MVP cutover:** 3 users on a CX22 (~€16/mo all-in). Scale up to CX32 (~€40/mo)
when onboarding more family.

---

## Approach

**One VPS, one Docker Compose stack, one cloud-init script.**

| Layer | Choice |
|-------|--------|
| IaC | OpenTofu (>= 1.8) |
| State backend | Hetzner Object Storage (S3-compatible), manually-created bucket |
| Compute | 1× Hetzner CX22 (fsn1 / Falkenstein), Debian 12 |
| Orchestration | Docker Compose (not Ansible — cloud-init + SSH is enough at this scale) |
| App stack | Nextcloud 30 (apache) + Postgres 16-alpine + Caddy 2 + Nextcloud cron container |
| Primary storage | Hetzner Object Storage bucket `family-cloud-data` (versioning on, 30-day non-current expiry) |
| DB storage | 20 GB Hetzner Cloud Volume at `/mnt/pgdata`, ext4 |
| DNS | Manual A record at Squarespace (post-`tofu apply`, IP is outputted) |
| TLS | Caddy auto-issues from Let's Encrypt |
| Admin SSH | Tailscale SSH only — **no public port 22** |
| Secrets | SOPS + age, `secrets/family-cloud.enc.yaml` in git, private key on laptop only |

**What's explicitly NOT in MVP:** backups, monitoring, Prometheus/Grafana,
fail2ban, multi-region, email/SMTP, cross-region replication. Weekend 2+ work.

---

## What's Done

### Documentation (committed to repo)

- **`PLAN.md`** — original implementation plan (user-authored) + `§0 Decisions
  Log` that I appended during review. Every deviation from the original plan is
  tracked there (server size, region, DNS provider, `use_path_style` syntax,
  provider pinning, `prevent_destroy`, etc.).
- **`PREREQUISITES.md`** — human action checklist. Tokens, tools, one-time
  bootstraps. This is the gate for `tofu init`.
- **`PROGRESS.md`** — this file.

### Infrastructure-as-Code (Tofu)

- **`tofu/versions.tf`** — pinned: `hcloud ~> 1.6`, `aws ~> 6.43`, `sops ~> 1.4`,
  OpenTofu `>= 1.8`. Links to each provider's GitHub repo.
- **`tofu/backend.tf`** — S3 backend pointed at Hetzner OS (fsn1). Modern
  syntax (`endpoints { s3 = ... }`, `use_path_style`, Ceph-specific skip flags).
- **`tofu/variables.tf`** — inputs with sensible defaults (CX22, fsn1,
  `stow.mcgeer.dev`, 20 GB volume, `s3_hostname = fsn1.your-objectstorage.com`).
  Only `operator_ssh_pubkey` has no default.
- **`tofu/terraform.tfvars.example`** — template for the human to copy to
  `terraform.tfvars` and fill in.
- **`tofu/main.tf`** — SOPS data source, `hcloud` provider (token from secrets),
  `aws` provider (as Hetzner OS S3 client with Ceph skip flags), `hcloud_ssh_key`,
  `aws_s3_bucket "nextcloud"` + versioning + lifecycle rule, module call.
- **`tofu/cloud-init.tf`** — renders `scripts/cloud-init.yaml.tpl` with SOPS
  secrets + `file()`-loaded Docker configs injected.
- **`tofu/outputs.tf`** — server IPv4/IPv6, Nextcloud bucket name, heredoc with
  manual Squarespace DNS instructions.
- **`tofu/modules/hetzner-server/`** — one module with `main.tf` (hcloud_server,
  hcloud_volume, hcloud_firewall, hcloud_volume_attachment, hcloud_rdns x2),
  `variables.tf`, `outputs.tf`. Port 22 intentionally NOT in firewall.

### Docker stack

- **`docker/docker-compose.yml`** — 4 services: `db` (postgres:16-alpine with
  tuned args), `nextcloud` (v30-apache with `OBJECTSTORE_S3_*` env-driven
  objectstore), `cron` (same image, `/cron.sh` entrypoint), `caddy` (2-alpine,
  ports 80/443 TCP+UDP).
- **`docker/Caddyfile`** — `stow.mcgeer.dev` reverse proxy, HSTS, CalDAV/CardDAV
  redirects, gzip/zstd, `max_body_size 10 GB` for large uploads.
- **`docker/nextcloud-config/custom.config.php`** — overlay with
  `filelocking.enabled => false` (S3 deadlock mitigation), `upload_tmp_dir` on
  the volume (CX22 only has 40 GB root), 30-day trash / 90-day versions, DE
  phone region, log level 2.

### Bootstrap

- **`scripts/cloud-init.yaml.tpl`** — cloud-init that installs Docker +
  Tailscale, mounts the Hetzner Volume at `/mnt/pgdata`, renders
  `docker-compose.yml` / `Caddyfile` / `custom.config.php` via `write_files`
  (indent(6) trick inside YAML block scalars), writes `.env` with SOPS-sourced
  secrets, registers the node into the `tag:family-cloud` tailnet, `docker
  compose up -d`.

### Git / secrets hygiene

- **`.gitignore`** — blocks tfstate, plaintext `secrets/*.yaml` (but allows
  `.enc.yaml` and `.example.yaml`), age keys, SSH keys, editor cruft.
- **`.sops.yaml`** — SOPS creation rule scoped to `secrets/.*\.enc\.yaml$`.
  Public key is a `<AGE_PUBLIC_KEY>` placeholder until the operator generates
  the keypair.
- **`secrets/family-cloud.example.yaml`** — plaintext shape of the eventual
  `.enc.yaml` secrets file. Committable (no real values).

---

## Current State — Not A Failure, A Handoff

We are **not** debugging anything. The code is at the point where everything
that can be done without live credentials is done. We are **blocked on the
human** to complete prerequisites.

### What's blocking progress

The operator (Devan) needs to complete `PREREQUISITES.md`:

1. Install `tofu`, `sops`, `age` locally
2. Generate Hetzner Cloud API token
3. Generate Hetzner Object Storage credentials → add as `hetzner` profile in
   `~/.aws/credentials`
4. Generate Tailscale auth key (tagged `tag:family-cloud`, reusable, non-ephemeral)
5. **Manually create** the `family-cloud-tfstate` bucket in Hetzner Object
   Storage (chicken-and-egg — backend needs it before `tofu init`)
6. Copy SSH public key

### The commit situation

Per user's global rules, Claude does not commit without explicit request. User
said "I'll commit the changes thanks, you can do the rest" — meaning the
commit is Devan's job, not mine. **Nothing is committed yet.** Run `git status`
to see.

---

## How To Resume From A Fresh Session

1. `cd /Users/devanmcgeer/devan.projects/family-cloud`
2. `git status && git log --oneline -10`
3. Read **this file** (`PROGRESS.md`)
4. Read **`PLAN.md §0 Decisions Log`** (top of the file) for decisions history
5. Read **`PREREQUISITES.md`** to see what the human still owes
6. If prereqs are done:
   - Generate age keypair: `age-keygen -o ~/.config/sops/age/keys.txt`
   - Paste the public key into `.sops.yaml` (replacing `<AGE_PUBLIC_KEY>`)
   - Create `secrets/family-cloud.enc.yaml` from the `.example.yaml` shape with
     real values, then `sops --encrypt --in-place secrets/family-cloud.enc.yaml`
   - Copy `tofu/terraform.tfvars.example` → `tofu/terraform.tfvars`, fill in
     `operator_ssh_pubkey`
   - `cd tofu && tofu init`
   - `tofu plan` — review, hand to user for approval
   - `tofu apply` — **spends money**; requires explicit sign-off
7. If prereqs are not done: report status, wait for human action

---

## Open Flags / Known-Fragile Areas

- **`indent(6, ...)` inside cloud-init YAML block scalars** — should work with
  PyYAML but is the kind of thing that breaks subtly. Dry-run with `tofu
  console` → `templatefile(...)` before first `tofu apply`.
- **Hetzner volume device discovery** via `find /dev/disk/by-id -name
  "scsi-0HC_Volume_*"` assumes exactly one volume attached.
- **`prevent_destroy` is commented out** on `hcloud_server`, `hcloud_volume`,
  and `aws_s3_bucket "nextcloud"` — marked with `TODO(post-first-deploy)`.
  Uncomment after the first successful iteration so destroy-by-accident is
  blocked.
- **Nextcloud 30-apache** is the pinned tag. When upgrading, do one major at a
  time per PLAN.md §5.2; runbook not yet written.
- **DNS is manual** — `tofu output dns_instructions` emits the Squarespace
  steps. Future: migrate to Route53 or Cloudflare for a `tofu`-managed A record.

---

## Session History (append-only)

- **2026-04-22/23 — initial scaffolding session**
  - Plan review, captured 11 decisions in `PLAN.md §0`
  - Built all IaC + Docker + cloud-init scaffolding
  - Dropped backup scaffolding from Weekend-1 scope (plan correctly
    scheduled it for Weekend 2)
  - Stopped: waiting on human prereqs + commit
