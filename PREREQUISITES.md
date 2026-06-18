# Prerequisites — Human Action Checklist

> Read this before anything else. Tofu will not run until every item here is done.
> This document is the **single source of truth** for what the human operator must provide.

---

## TL;DR

Before `tofu init` will succeed you need:

1. Tools installed on your laptop (`tofu`, `sops`, `age`, `hcloud` CLI optional)
2. A Hetzner Cloud project with an **API token**
3. Hetzner **Object Storage credentials** (separate from the Cloud API)
4. A **Tailscale** auth key
5. An **age keypair** on your laptop (we'll generate this in Task 1)
6. Your **SSH public key** registered
7. A **Hetzner state bucket** created manually (one-time bootstrap)
8. `mcgeer.dev` DNS access (Squarespace for now — manual A record)

Full details below.

---

## 1. Install Local Tooling

```bash
# macOS (Homebrew)
brew install opentofu sops age
# Optional — Hetzner CLI for ad-hoc inspection
brew install hcloud
```

Verify:

```bash
tofu version      # expect >= 1.8
sops --version
age --version
```

---

## 2. Hetzner Cloud — API Token

**What:** Read/write API token scoped to a single Cloud project.

**How:**
1. Sign in at https://console.hetzner.cloud/
2. Create (or open) a project named `family-cloud`
3. Left sidebar → **Security** → **API Tokens** → **Generate API Token**
4. Description: `family-cloud-tofu`, Permissions: **Read & Write**
5. Copy the token — it's shown **once**

**Where it goes:** Into SOPS-encrypted secrets (`secrets/family-cloud.enc.yaml`) under `hcloud_token`. Task 1 will walk you through encryption.

**Revocation:** If leaked, revoke in the Hetzner console — the token grants full control of the project.

---

## 3. Hetzner Object Storage — Credentials

**What:** S3-compatible access key + secret for Hetzner Object Storage. Used for (a) Tofu state backend, (b) Nextcloud primary storage bucket, (c) Postgres backup bucket.

**How:**
1. https://console.hetzner.cloud/ → your project → **Object Storage** (left sidebar)
2. **Create Credentials** → Description: `family-cloud-tofu`
3. Region: **fsn1** (Falkenstein, Germany)
4. Copy both the **access key** and **secret access key** — the secret is shown **once**

**Endpoint you'll use:** `https://fsn1.your-objectstorage.com`

**Where they go:** SOPS-encrypted under `hcloud_s3_access_key` and `hcloud_s3_secret_key`.

**Note:** Hetzner Object Storage is S3-compatible but Ceph-backed. The Tofu config uses `use_path_style = true` and a custom endpoint. This is handled in the module.

---

## 4. Tailscale — Auth Key

**What:** A reusable, tagged auth key so cloud-init can register the VPS into your tailnet without human intervention.

**How:**
1. Sign up at https://tailscale.com/ (free tier — up to 3 users / 100 devices)
2. Admin console → **Settings** → **Keys** → **Generate auth key**
3. Options:
   - **Reusable:** ✅ (so `tofu apply` on a re-created server works)
   - **Ephemeral:** ❌ (we want the node to persist across reconnects)
   - **Tags:** `tag:family-cloud` (register this tag under **Access Controls** first — see below)
   - **Expiration:** 90 days (rotate quarterly)
4. Copy the key (starts with `tskey-auth-...`) — shown **once**

**ACL setup (do this once, before generating the key):**

Admin console → **Access Controls** → edit the tailnet policy, add:

```hujson
{
  "tagOwners": {
    "tag:family-cloud": ["your-tailscale-email@example.com"],
  },
  "acls": [
    { "action": "accept", "src": ["your-tailscale-email@example.com"], "dst": ["tag:family-cloud:*"] },
  ],
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:family-cloud"],
      "users":  ["root", "autogroup:nonroot"],
    },
  ],
}
```

**Where it goes:** SOPS-encrypted under `tailscale_authkey`.

---

## 5. age Keypair (SOPS Encryption)

**What:** Modern replacement for PGP. SOPS uses this to encrypt `secrets/family-cloud.enc.yaml` in git.

**Generated during Task 1** — we'll run:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

**Critical:**
- The **private key** (`~/.config/sops/age/keys.txt`) **never goes in git**. Back it up to your password manager (1Password, Bitwarden — save the full file contents as a secure note).
- The **public key** (starts with `age1...`) goes in `.sops.yaml` and is safe to commit.

**Loss of the private key = permanent loss of every SOPS-encrypted secret in this repo.** Back it up before committing anything.

---

## 6. SSH Public Key

**What:** Your laptop's SSH public key, added as an `hcloud_ssh_key` resource so the server accepts you on port 22 during bootstrap (until Tailscale SSH takes over).

**How:**
```bash
cat ~/.ssh/id_ed25519.pub  # or id_rsa.pub
```

**Where it goes:** As a Tofu variable in `tofu/terraform.tfvars` (plaintext — public key is public). Task 2 will wire this in.

**If you don't have an SSH key yet:**
```bash
ssh-keygen -t ed25519 -C "your@email"
```

---

## 7. Manual Bootstrap — Tofu State Bucket

**What:** A chicken-and-egg problem — Tofu's S3 state backend needs a bucket that exists *before* Tofu runs. One-time manual step.

**How:**
1. https://console.hetzner.cloud/ → your project → **Object Storage** → **Create Bucket**
2. Name: `family-cloud-tfstate`
3. Region: **fsn1**
4. ACL: **Private** (default)
5. **Enable Versioning** on the bucket (so we can recover from bad `tofu apply` state corruption)

**Verify:**
```bash
aws s3 ls --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner  # configure profile with your Object Storage credentials
```

You should see the empty bucket.

---

## 8. DNS — `mcgeer.dev`

**What:** An `A` record pointing `stow.mcgeer.dev` to the Hetzner server's IPv4 address.

**Current provider:** Squarespace.

**MVP approach:** Manual. After Task 2 completes, Tofu outputs the server IP; you log into Squarespace DNS management and create:
- Type: `A`
- Host: `stow`
- Value: `<server IP from tofu output>`
- TTL: `300` (low so you can change it easily)

**Post-MVP automation path:** Move `mcgeer.dev` DNS to AWS Route53 or Cloudflare (both have Tofu providers). Lets `tofu apply` manage the record. Non-blocking for MVP.

---

## Summary Checklist

Copy this to track progress:

```
[ ] Installed tofu, sops, age on laptop
[ ] Hetzner Cloud API token generated and saved temporarily
[ ] Hetzner Object Storage credentials generated and saved temporarily
[ ] Tailscale account + ACL policy updated + auth key generated
[ ] age keypair generated (will happen in Task 1)
[ ] SSH public key copied (`cat ~/.ssh/id_ed25519.pub`)
[ ] `family-cloud-tfstate` bucket created manually in Hetzner Object Storage
[ ] Squarespace DNS access confirmed (for stow.mcgeer.dev A record later)
```

Once every box is ticked, Task 1 can proceed.
