# Family Cloud Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a self-hosted Nextcloud instance on Hetzner Cloud with S3 primary storage for ~10 family users (5TB total), fully provisioned via OpenTofu + cloud-init.

**Architecture:** Single Hetzner CX22 VPS (fsn1) running Docker Compose (Nextcloud + Postgres + Caddy + Tailscale). Hetzner Object Storage as Nextcloud primary storage. Cloud-init bootstraps everything from scratch — cattle, not pets. SOPS + age for secrets in git.

**Tech Stack:** OpenTofu, Hetzner Cloud, Docker Compose, Nextcloud, PostgreSQL 16, Caddy, Tailscale, SOPS/age

**Domain:** `stow.mcgeer.dev` (subdomain of `mcgeer.dev`, DNS at Squarespace — manual A record post-apply).

> **Human setup:** see [`PREREQUISITES.md`](./PREREQUISITES.md) for every account, token, and key the operator must provide before `tofu init`.

---

## 0. Decisions Log (Deviations From Original Plan)

Recorded during plan review on 2026-04-22. Later sections reflect these.

| # | Decision | Rationale |
|---|----------|-----------|
| 0.1 | Server: **CX22** (not CX31) | CX31 deprecated. CX22 (2 vCPU Intel, 4GB, 40GB NVMe, ~€3.29/mo) covers 3-user MVP; scale up non-disruptively later via `tofu apply`. |
| 0.2 | Region: **fsn1** (Falkenstein) | Closest German Hetzner region. Both server and Object Storage co-located. |
| 0.3 | Storage: **Hetzner Object Storage** (kept) | AWS S3 considered (§1 review) but rejected — 5× more expensive at 5TB scale. Hetzner OS is S3-compatible, Ceph-backed. |
| 0.4 | DNS: **Squarespace manual A record** for MVP | Squarespace has no Tofu provider. Post-MVP move to Route53 or Cloudflare for automation. |
| 0.5 | **Tailscale in MVP** (kept) | Avoids public port 22 exposure. Free tier fine for this scale. Auth key + ACL tag `tag:family-cloud`. |
| 0.6 | Tofu S3 backend uses modern syntax | `use_path_style = true` and `endpoints = { s3 = "..." }` block — `force_path_style` is deprecated since OpenTofu 1.6 / AWS provider 5.x. |
| 0.7 | Secrets via `sops_file` data source | `carlpett/sops` provider; `data.sops_file.secrets.data["key"]`. Not `sops_decrypt` as the original plan implied. |
| 0.8 | Cloud-init strategy: **Option A — inline via Tofu `templatefile()` + `write_files`** | Keeps git as source of truth; no deploy-key or signed-URL complexity. |
| 0.9 | `prevent_destroy` lifecycle blocks on: `hcloud_server`, `hcloud_volume`, Nextcloud data bucket, backup bucket | §7.1 called this out but §2.2 didn't. Now explicit. |
| 0.10 | `awscli` installed by cloud-init | Required by `backup-db.sh`; omitted from the original Task 5. |
| 0.11 | Provider pinning | `hcloud ~> 1.48`, `aws ~> 5.70`, `sops ~> 1.1`, OpenTofu `~> 1.8`. Links to provider repos commented in `versions.tf`. |

---

## 1. Architecture Decisions

### 1.1 Database: Self-Hosted Postgres 16 in Docker

**Decision:** Self-hosted PostgreSQL 16 in Docker on the same VPS.

**Why:** Hetzner has no managed PostgreSQL offering. Third-party managed (e.g. Ubicloud at ~EUR12/mo) adds cost and a network hop for minimal benefit at this scale. 10 users generating metadata — this is a trivially small Postgres workload. A CX22 with 4GB RAM is tight but fits the 3-user MVP; scale up to CX32/CPX31 before adding more users.

**Config:**
- Postgres 16 Alpine image, pinned to minor version
- 20GB Hetzner Cloud Volume mounted at `/mnt/pgdata` (EUR1.14/mo)
- `max_connections = 100`, `shared_buffers = 256MB`, `work_mem = 4MB`
- Daily `pg_dump` to Object Storage via cron

**Tradeoff accepted:** You own upgrades and backups. But at this scale, `pg_dump` + Docker image tag bump is 15 minutes of work per quarter. Worth the EUR12/mo savings and reduced complexity.

### 1.2 Access: Public HTTPS for Family, Tailscale for Admin

**Decision:** Dual-stack. Public HTTPS on a real domain for all family access. Tailscale for SSH admin access only.

**Why:** Non-technical family members will not install Tailscale. They need `stow.mcgeer.dev` in a browser and the Nextcloud mobile app pointed at a public URL. Tailscale-only access for 10 users including parents/grandparents is a support nightmare that kills adoption.

**Security posture:**
- Caddy handles TLS termination with automatic Let's Encrypt
- Hetzner Cloud Firewall: allow 80/443 inbound (public), 22 only via Tailscale
- Nextcloud brute-force protection enabled (default)
- Fail2ban as post-MVP hardening (not worth the cloud-init complexity for Weekend 1)

### 1.3 Reverse Proxy: Caddy

**Decision:** Caddy v2.

**Why:** Automatic HTTPS with zero config (no certbot cron, no renewal scripts). Native Tailscale integration for admin endpoints. The entire Caddyfile for this project is ~15 lines. Traefik's label-based discovery is overkill for a single-app Docker Compose stack. Nginx requires manual certbot setup.

**Caddyfile:**
```
stow.mcgeer.dev {
    reverse_proxy nextcloud:80
    header Strict-Transport-Security "max-age=31536000"

    # Nextcloud CalDAV/CardDAV discovery
    redir /.well-known/carddav /remote.php/dav 301
    redir /.well-known/caldav /remote.php/dav 301
}
```

### 1.4 Provisioning: Immutable-Infra with Cloud-Init (Zero Ansible)

**Decision:** Cloud-init bootstraps Docker, pulls images, writes config files, starts Compose. No Ansible. SSH via Tailscale is the escape hatch for `occ` commands.

**Why:** For a single-VPS setup, cloud-init covers 95% of provisioning needs. The remaining 5% (running `occ` one-offs, debugging) is handled by SSH. Ansible adds a tool, an inventory, and a mental model you don't need for one server.

**What this costs you:**
- `occ maintenance:mode --on` before upgrades requires SSH. This is fine — you'll do major upgrades maybe twice a year.
- If cloud-init fails on first boot, you SSH in to debug. Mitigate by testing the cloud-init script against a throwaway CX11 first (EUR0.007/hr).

**What breaks zero-Ansible:**
- Nothing at this scale. If you grow to 3+ servers, revisit. For one VPS, cloud-init + SSH + Docker Compose is the right tool.

---

## 2. OpenTofu Module Structure

### 2.1 Repo Layout

```
family-cloud/
├── PLAN.md
├── .sops.yaml                    # SOPS config (age key reference)
├── secrets/
│   └── family-cloud.enc.yaml     # Encrypted secrets (DB pass, Tailscale key, etc.)
├── tofu/
│   ├── main.tf                   # Root module — wires everything together
│   ├── variables.tf              # Input variables
│   ├── outputs.tf                # Server IP, domain, etc.
│   ├── versions.tf               # Provider + Tofu version constraints
│   ├── backend.tf                # S3 state backend config
│   ├── cloud-init.tf             # Template rendering for user_data
│   └── modules/
│       └── hetzner-server/
│           ├── main.tf           # hcloud_server + volume + firewall + DNS
│           ├── variables.tf
│           └── outputs.tf
├── docker/
│   ├── docker-compose.yml        # Nextcloud + Postgres + Caddy
│   ├── Caddyfile                 # Reverse proxy config
│   └── nextcloud-config/
│       └── custom.config.php     # S3 backend, trusted proxies, etc.
├── scripts/
│   ├── cloud-init.yaml.tpl       # Cloud-init template (Tofu templatefile)
│   ├── backup-db.sh              # pg_dump to S3 script
│   └── provision-users.sh        # occ user creation script (run once via SSH)
└── docs/
    └── runbooks/
        ├── upgrade-nextcloud.md
        └── restore-from-backup.md
```

### 2.2 Module Decisions

**One module: `hetzner-server`**. It owns:
- `hcloud_server` (the VPS)
- `hcloud_volume` (Postgres data)
- `hcloud_volume_attachment`
- `hcloud_firewall` + rules
- `hcloud_rdns` (reverse DNS)

**Inline in root (not a module):**
- `hcloud_ssh_key` — one resource, no reuse
- Object Storage bucket — use `aws` provider with Hetzner S3 endpoint (the `hcloud` provider doesn't support bucket provisioning)
- DNS records if using Hetzner DNS, or manage externally

**Why not more modules?** YAGNI. One server, one volume, one firewall. Modules exist for reuse — there's nothing to reuse here. If you add a staging environment later, extract then.

### 2.3 State Management

**Decision:** Hetzner Object Storage as S3 backend.

```hcl
# backend.tf — OpenTofu >= 1.8 / AWS provider >= 5.x syntax
terraform {
  backend "s3" {
    bucket = "family-cloud-tfstate"
    key    = "prod/terraform.tfstate"
    region = "eu-central-1"  # dummy — Hetzner OS doesn't validate, but the AWS SDK requires one

    endpoints = {
      s3 = "https://fsn1.your-objectstorage.com"
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
```

**Syntax notes (deviations from original plan):**
- `force_path_style` → `use_path_style` (renamed in AWS provider 5.x).
- `endpoint = "..."` → `endpoints { s3 = "..." }` block (also 5.x).
- Added `skip_requesting_account_id` and `skip_s3_checksum` — required for Ceph-backed S3 (Hetzner uses Ceph); without them `tofu init` fails with `InvalidAccessKeyId` or checksum mismatches.

**Why not local state?** You'll run Tofu from multiple machines (laptop + maybe CI). Remote state avoids "where's the state file" problems. Hetzner Object Storage costs EUR4.99/mo and you're already paying for it for Nextcloud storage — the state file adds negligible cost.

---

## 3. User and Sharing Model

### 3.1 User Provisioning: Script via SSH (Run Once)

**Decision:** A shell script (`scripts/provision-users.sh`) that calls `occ` inside the Docker container. Run manually via SSH after first deployment.

```bash
#!/bin/bash
set -euo pipefail

CONTAINER="nextcloud-app"
USERS=("alice" "bob" "carol" "dave" "eve" "frank" "grace" "hank" "iris" "jack")
QUOTA="500 GB"
GROUP="family"

docker exec -u www-data "$CONTAINER" php occ group:create "$GROUP" || true

for user in "${USERS[@]}"; do
    echo "Creating user: $user"
    docker exec -u www-data "$CONTAINER" php occ user:add \
        --display-name "${user^}" \
        --group "$GROUP" \
        "$user" <<< "$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)"
    docker exec -u www-data "$CONTAINER" php occ user:setting "$user" files quota "$QUOTA"
done
```

**Why not cloud-init?** Nextcloud must be fully initialized before `occ` works. Cloud-init runs at boot before Docker containers are healthy. You'd need polling/retry logic that's fragile. Running the script once via SSH after confirming the stack is up is simpler and more reliable.

**Why not the Provisioning API?** It works, but `occ` is simpler for a one-time setup of 10 users. The API is better if you're automating ongoing user management from an external system.

### 3.2 Quota Enforcement

Set per-user via `occ user:setting USERNAME files quota "500 GB"`. This is enforced by Nextcloud at the application layer — it checks quota before accepting uploads regardless of backend (S3, local, etc.).

### 3.3 Shared Family Folders

**Decision:** Install the Group Folders app post-deployment.

```bash
docker exec -u www-data nextcloud-app php occ app:enable groupfolders
docker exec -u www-data nextcloud-app php occ groupfolders:create "Family Photos"
docker exec -u www-data nextcloud-app php occ groupfolders:group 1 family write
docker exec -u www-data nextcloud-app php occ groupfolders:quota 1 "500 GB"
```

**Critical S3 gotcha:** Files >10MB moved (not copied) from a user folder to a Group Folder can be silently lost on S3 backends. This is a known Nextcloud bug. **Mitigation:** Tell family to always *copy* to shared folders, or upload directly to the shared folder. Document this in onboarding.

---

## 4. Backup and Disaster Recovery

### 4.1 Postgres Backup

**Strategy:** Daily `pg_dump` compressed and uploaded to a *separate* Object Storage bucket.

```bash
# scripts/backup-db.sh — runs via cron on host
#!/bin/bash
set -euo pipefail
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUCKET="family-cloud-backups"
ENDPOINT="https://fsn1.your-objectstorage.com"

docker exec nextcloud-db pg_dump -U nextcloud -Fc nextcloud \
  | gzip > "/tmp/nextcloud-db-${TIMESTAMP}.sql.gz"

aws s3 cp "/tmp/nextcloud-db-${TIMESTAMP}.sql.gz" \
  "s3://${BUCKET}/postgres/${TIMESTAMP}.sql.gz" \
  --endpoint-url "$ENDPOINT"

rm "/tmp/nextcloud-db-${TIMESTAMP}.sql.gz"

# Retain 30 days
aws s3 ls "s3://${BUCKET}/postgres/" --endpoint-url "$ENDPOINT" \
  | awk '{print $4}' | sort | head -n -30 \
  | xargs -I{} aws s3 rm "s3://${BUCKET}/postgres/{}" --endpoint-url "$ENDPOINT"
```

**Cadence:** Daily at 03:00 UTC via host crontab (set in cloud-init).
**Retention:** 30 days rolling.

### 4.2 Object Storage (File Data)

**Strategy:** Hetzner Object Storage has built-in 3x replication within the region. Enable versioning on the bucket for accidental deletion protection.

```hcl
resource "aws_s3_bucket_versioning" "nextcloud" {
  bucket = aws_s3_bucket.nextcloud.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

**Lifecycle rule:** Expire non-current versions after 30 days to control costs.

**No cross-region replication for MVP.** Hetzner Object Storage doesn't support it natively, and the data is already 3x replicated within the datacenter. Cross-region backup is a post-MVP concern.

### 4.3 RTO/RPO

| Scenario | RPO | RTO | Notes |
|----------|-----|-----|-------|
| VPS dies | 0 (files on S3) + 24h (DB) | ~1 hour | `tofu apply` + restore DB dump |
| DB corruption | 24 hours | ~30 min | Restore latest `pg_dump` |
| Accidental file delete | 30 days (versioning) | ~5 min | Restore from S3 versions |
| S3 region outage | 0 (during outage: unavailable) | Hetzner SLA | No mitigation without cross-region |

### 4.4 Testing Backups

- Monthly: download latest `pg_dump`, restore to local Docker Postgres, verify row counts
- Quarterly: full DR test — `tofu apply` a second VPS, restore DB, point at same S3 bucket (read-only), verify files accessible
- Automate the monthly check as a script in `scripts/test-backup.sh` post-MVP

---

## 5. Operational Concerns

### 5.1 Monitoring (MVP)

**Decision:** Minimal external monitoring only. No Prometheus/Grafana stack.

- **Uptime:** Use a free tier external monitor (Uptime Robot, Hetrix Tools, or similar) — ping `stow.mcgeer.dev` every 5 minutes, alert via email/Telegram
- **Disk:** Cloud-init sets a cron job that checks volume usage and sends a webhook if >80%
- **DB:** The `pg_dump` backup script doubles as a health check — if it fails, the cron error email alerts you

**Not MVP:** Prometheus, Grafana, node_exporter, Nextcloud metrics endpoint. These are "meta-optimisation over shipping."

### 5.2 Nextcloud Upgrades

**Process (run ~2x per year):**
1. SSH in via Tailscale
2. `docker exec -u www-data nextcloud-app php occ maintenance:mode --on`
3. Snapshot the Hetzner Cloud Volume (Postgres data)
4. Update Docker image tag in `docker-compose.yml` (one major version at a time)
5. `docker compose pull && docker compose up -d`
6. Wait for migrations: `docker logs -f nextcloud-app`
7. `docker exec -u www-data nextcloud-app php occ maintenance:mode --off`
8. Verify in browser, commit new image tag to git

**Critical:** Nextcloud cannot skip major versions. 28 -> 29 -> 30, never 28 -> 30.

Document this as `docs/runbooks/upgrade-nextcloud.md`.

### 5.3 Family Support

**Realities:**
- You're the sole admin, relocating to Germany (different timezone from some family)
- Non-technical users will message you on WhatsApp when something breaks

**Mitigations:**
- Nextcloud mobile/desktop apps reduce "how do I" questions — install during onboarding
- Write a 1-page "Family Cloud Quick Start" doc: how to log in, upload, share, mobile app links
- Set up a "Family Cloud" group chat for support requests (visible to you async)
- External uptime monitor means you know before they tell you

### 5.4 Cost Projection (3 Years)

**Monthly costs (EUR, post-April 2026 pricing):**

*MVP phase (3 users, ~500GB storage):*
| Item | Monthly | Notes |
|------|---------|-------|
| CX22 (2 vCPU Intel, 4GB, 40GB NVMe) | ~EUR3.29 | Upgrade to CX32/CPX31 before adding user 4+ |
| Object Storage (~500GB) | ~EUR4.99 | Base tier includes 1TB — no overage at MVP |
| Cloud Volume (20GB) | EUR1.14 | Postgres data |
| Domain (`mcgeer.dev`) | ~EUR1 | Existing, amortized |
| Server backups (20%) | ~EUR0.66 | Hetzner automatic snapshots |
| Backup bucket | ~EUR5 | Separate bucket for DB dumps |
| **Total (MVP)** | **~EUR16/mo** | |

*At target scale (10 users, 5TB storage):*
| Item | Monthly | Notes |
|------|---------|-------|
| CX32 (4 vCPU Intel, 8GB) | ~EUR6.80 | When adding more users |
| Object Storage (5TB) | ~EUR25 | EUR4.99 base + ~EUR20 for 4TB overage |
| Cloud Volume (20GB) | EUR1.14 | Postgres data |
| Domain | ~EUR1 | |
| Server backups (20%) | ~EUR1.36 | |
| Backup bucket | ~EUR5 | |
| **Total (scale)** | **~EUR40/mo** | |

**Year 1 (MVP all year):** ~EUR200
**Year 3 (assuming gradual scale-up):** ~EUR450/yr plateau = ~EUR1,100 cumulative

**Cost surprise risks:**
- Object Storage egress if family downloads heavily (EUR1/TB, unlikely to matter)
- Storage growth faster than expected — monitor and adjust quotas
- Hetzner price changes (they just raised prices 30% in April 2026)

**Comparison:** Google One 2TB family plan is ~EUR10/mo but only 2TB shared. At 5TB with user isolation, self-hosting is cost-competitive.

---

## 6. MVP Scope and Shipping Plan

### 6.1 MVP Definition (What's IN)

- Single Hetzner VPS provisioned via OpenTofu
- Docker Compose: Nextcloud + Postgres + Caddy
- S3 primary storage on Hetzner Object Storage
- Public HTTPS with automatic Let's Encrypt
- Tailscale for admin SSH
- 10 users with 500GB quotas
- One shared "Family Photos" Group Folder
- Daily Postgres backups to S3
- External uptime monitoring
- S3 bucket versioning enabled
- SOPS-encrypted secrets in git

### 6.2 NOT MVP (Explicitly Deferred)

- Custom UI on WebDAV/OCS APIs
- Prometheus/Grafana monitoring
- HA or multi-server setup
- Cross-region backup replication
- Automated user onboarding UX
- Fail2ban / advanced security hardening
- Nextcloud Office / Collabora integration
- Automated upgrade pipeline
- CI/CD for infrastructure changes
- Email notifications (Nextcloud SMTP config — add post-MVP when convenient)

### 6.3 Weekend Milestones

#### Weekend 1: Infrastructure + Running Nextcloud

**Goal:** `tofu apply` produces a VPS with Nextcloud accessible over HTTPS.

**Tasks:**

##### Task 1: Repository + Secrets Foundation
**Files:**
- Create: `tofu/versions.tf`
- Create: `tofu/variables.tf`
- Create: `tofu/backend.tf`
- Create: `.sops.yaml`
- Create: `secrets/family-cloud.enc.yaml`

**Steps:**
1. Initialize Tofu project with `hcloud` and `aws` providers
2. Configure S3 backend for state (manually create bucket first via Hetzner console)
3. Set up SOPS with age — generate age keypair, configure `.sops.yaml`
4. Encrypt initial secrets: DB password, Tailscale auth key, S3 credentials
5. `tofu init` — verify backend connection
6. Commit: `feat: initialize tofu project with S3 state backend`

##### Task 2: Server Module + Cloud-Init
**Files:**
- Create: `tofu/modules/hetzner-server/main.tf`
- Create: `tofu/modules/hetzner-server/variables.tf`
- Create: `tofu/modules/hetzner-server/outputs.tf`
- Create: `tofu/main.tf`
- Create: `tofu/outputs.tf`
- Create: `scripts/cloud-init.yaml.tpl`

**Steps:**
1. Write `hetzner-server` module: `hcloud_server` + `hcloud_volume` + `hcloud_firewall`
2. Write cloud-init template: install Docker, Tailscale, write Docker Compose + config files
3. Wire root module: decrypt secrets via `sops_decrypt`, pass to module
4. `tofu plan` — review resources to be created
5. `tofu apply` — provision the VPS
6. Verify: SSH in via Tailscale, confirm Docker running
7. Commit: `feat: add hetzner server module with cloud-init bootstrap`

##### Task 3: Docker Compose + Nextcloud
**Files:**
- Create: `docker/docker-compose.yml`
- Create: `docker/Caddyfile`
- Create: `docker/nextcloud-config/custom.config.php`

**Steps:**
1. Write Docker Compose: Nextcloud (apache image), Postgres 16, Caddy
2. Write Caddyfile with domain + Nextcloud reverse proxy
3. Write `custom.config.php` with S3 backend, trusted proxies, overwrite protocol
4. Embed these in cloud-init template (or have cloud-init pull from a known location)
5. Create S3 bucket for Nextcloud data via Tofu (`aws_s3_bucket` with Hetzner endpoint)
6. `tofu apply` fresh (destroy + recreate to test full cloud-init flow)
7. Verify: `https://stow.mcgeer.dev` shows Nextcloud login
8. Commit: `feat: add docker compose stack with caddy and s3 storage`

**Weekend 1 exit criteria:** Nextcloud admin login works over public HTTPS. Tailscale SSH works. Files uploaded appear in S3 bucket.

---

#### Weekend 2: Users + Backups + Stability

**Goal:** All family users created with quotas. Backups running. System stable enough for soft launch.

##### Task 4: User Provisioning
**Files:**
- Create: `scripts/provision-users.sh`

**Steps:**
1. Write user provisioning script (occ commands for all 10 users)
2. SSH in, run script
3. Verify: log in as two different users, upload files, confirm quota shown
4. Enable Group Folders app, create "Family Photos" folder
5. Verify: both users can see and upload to shared folder
6. Commit: `feat: add user provisioning script`

##### Task 5: Backup System
**Files:**
- Create: `scripts/backup-db.sh`

**Steps:**
1. Create backup S3 bucket via Tofu
2. Write `backup-db.sh` script
3. Add crontab entry to cloud-init template (daily 03:00 UTC)
4. Enable S3 versioning on the Nextcloud data bucket (Tofu)
5. Add lifecycle rule: expire non-current versions after 30 days
6. Test: run backup manually, verify dump appears in backup bucket
7. Test: restore dump to local Postgres, verify tables present
8. Commit: `feat: add automated postgres backup to s3`

##### Task 6: Monitoring + DNS
**Steps:**
1. Set up external uptime monitor (free tier) on `stow.mcgeer.dev`
2. Configure alert destination (email or Telegram)
3. Add volume usage check cron to cloud-init
4. Verify: take Caddy down briefly, confirm alert fires
5. Set up proper DNS (if not done in Weekend 1)

**Weekend 2 exit criteria:** All users can log in. Backups verified. Uptime monitor active. Ready for soft launch with 2-3 family members.

---

#### Weekend 3: Onboarding + Hardening + Launch

**Goal:** All family members onboarded. System hardened. Documentation complete.

##### Task 7: Documentation + Onboarding
**Files:**
- Create: `docs/runbooks/upgrade-nextcloud.md`
- Create: `docs/runbooks/restore-from-backup.md`
- Create: `docs/family-quickstart.md` (for family members)

**Steps:**
1. Write upgrade runbook (step-by-step Nextcloud major version upgrade)
2. Write restore runbook (DB restore + full DR recovery)
3. Write family quickstart: login URL, mobile app links, how to share files
4. Onboard 2-3 early adopters (help them install mobile app, upload first files)
5. Commit: `docs: add operational runbooks and family quickstart guide`

##### Task 8: Hardening + Full Launch
**Steps:**
1. Review Nextcloud security scan (`https://scan.nextcloud.com`)
2. Ensure `config.php` has proper `trusted_domains`
3. Verify Hetzner Firewall rules (only 80/443 public)
4. Set Nextcloud background jobs to cron mode (not AJAX)
5. Add cron container or host crontab for `cron.php`
6. Onboard remaining family members
7. Commit: `feat: harden nextcloud security and background jobs`

**Weekend 3 exit criteria:** All family members have accounts and have logged in at least once. Mobile apps installed. Shared folder in use. Runbooks committed. You can sleep at night.

---

## 7. Red Flags and Risks

### 7.1 Data Loss Scenarios

| Scenario | Likelihood | Impact | Mitigation |
|----------|-----------|--------|------------|
| S3 bucket accidentally deleted | Low | **Catastrophic** | Tofu `prevent_destroy`, bucket versioning, separate backup bucket |
| DB corruption without recent backup | Low | High (metadata lost, files become orphaned blobs) | Daily `pg_dump`, test restores quarterly |
| Group Folder file loss (>10MB move bug) | Medium | Medium | Educate users to copy, not move. Monitor Nextcloud issue tracker for fix |
| `tofu destroy` run accidentally | Low | **Catastrophic** | Use `prevent_destroy` on server + volume. Separate state for destructive vs non-destructive resources |
| Hetzner account compromised | Very Low | **Catastrophic** | 2FA on Hetzner account. SOPS for secrets in git. Separate backup bucket with restricted credentials |

### 7.2 Cost Surprise Risks

- **Object Storage egress:** Unlikely to matter at family scale. 10 users won't generate TB of downloads.
- **Hetzner price increases:** They just raised prices ~30% in April 2026. Budget EUR60/mo as ceiling, not EUR45.
- **Storage growth:** If users treat it like a photo dump, 500GB fills faster than expected. Monitor quarterly. Quotas are your friend.
- **Snapshot costs:** EUR0.011/GB/mo. A 40GB server snapshot = EUR0.44/mo. Don't let old snapshots accumulate.

### 7.3 Complexity Debt (6-Month Risks)

- **Nextcloud major version upgrade:** Sequential-only upgrades mean falling behind creates a painful catch-up. **Mitigation:** Upgrade within 2 months of each major release. Put it on your calendar.
- **Cloud-init drift:** Config in git diverges from what's actually running. **Mitigation:** Treat VPS as disposable. Quarterly: destroy and recreate from `tofu apply` to verify cloud-init still works. (Drain users first or test with a parallel instance.)
- **S3 file hash opacity:** Files on S3 are stored as `urn:oid:XXXX` — you can't browse them meaningfully without the DB. **Mitigation:** Never lose the DB. Backup strategy is critical.
- **Single point of failure:** One VPS, one region. Acceptable for family use, but if Hetzner Falkenstein has an extended outage, you're down. **Mitigation:** Accept this for MVP. Cross-region is post-MVP.

### 7.4 Nextcloud + S3 Gotchas

1. **`use_path_style` must be `true`** for Hetzner Object Storage (Ceph-backed). Virtual-hosted style won't work.
2. **Disable file locking** (`'filelocking.enabled' => false`) or face deadlocks with S3. This is counterintuitive but well-documented.
3. **Large file uploads need adequate `/tmp`** on the VPS. Files >80MB buffer through `/tmp` before S3 upload. **CX22 only has 40GB NVMe** — this is tight. Set `upload_tmp_dir` to the 20GB volume (or a bind-mount from it) to avoid filling root disk during multi-GB uploads.
4. **First login per user takes 1-2 minutes** as Nextcloud scaffolds their storage on S3. Warn family during onboarding.
5. **Group Folders + S3 move bug:** Files >10MB silently lost when moved (not copied) to Group Folders. Known issue. Educate or disable moves via a Nextcloud workflow rule if available.

---

## Verification

After full implementation, verify end-to-end:

1. **Infrastructure:** `tofu plan` shows no changes (state matches reality)
2. **Access:** `https://stow.mcgeer.dev` loads Nextcloud login (test from phone on cellular, not home network)
3. **User flow:** Log in as a test user, upload a 100MB file, verify it appears in S3 bucket
4. **Sharing:** Upload to Group Folder from one user, verify visible from another
5. **Quotas:** Upload enough to approach quota, verify warning appears
6. **Backup:** Run `backup-db.sh` manually, download the dump, restore to local Postgres, verify tables
7. **Recovery:** Destroy VPS, `tofu apply`, restore DB, verify files accessible
8. **Monitoring:** Stop Caddy, verify uptime alert fires within 10 minutes
9. **Admin access:** SSH via Tailscale, run `occ status`, verify output
