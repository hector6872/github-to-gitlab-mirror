# GitHub → GitLab Mirror

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A lightweight, system-agnostic script that mirrors **every repository of a GitHub account** (and optional organizations) into **GitLab** (all branches + tags). It detects remote changes, repairs drift, optionally auto-creates missing GitLab projects, and can notify you via email or webhook when errors occur.

Runs anywhere: **macOS, any Linux distribution, Raspberry Pi, VPS, or containers**. It requires **no root permissions**, no browser, and no heavy runtime dependencies.

---

## Highlights

- **Agnostic & Lightweight**: Runs in-place with no root/`sudo` required. Only needs `bash`, `git`, `curl`, and `jq`.
- **Environment-based Configuration**: Put settings into a `.env` file or provide ambient environment variables.
- **Auto-detection**: Automatically discovers your GitHub and GitLab usernames from tokens.
- **Robust Mirroring**: Uses `git init --bare` + `fetch` + `push --mirror`. Keeps branches and tags synced while pruning deleted refs.
- **Drift Repair**: Detects whether GitLab is out of sync even if GitHub has not changed, ensuring integrity.
- **Dry-run Mode**: Compare remote states and preview actions before making any modifications.
- **Optional Notifications**: Send failure reports via email (`msmtp`, `sendmail`, `mail`) or webhooks (Slack, Discord, Mattermost).

---

## Prerequisites

Ensure these CLI tools are installed on your system:

- **git** (v2.20+)
- **curl**
- **jq**
- Optional: **msmtp** or **sendmail** (for email alerts)

Package manager install commands:
- **macOS (Homebrew)**: `brew install git curl jq msmtp`
- **Debian / Ubuntu / Raspberry Pi OS**: `sudo apt install git curl jq msmtp`
- **Arch Linux**: `sudo pacman -S git curl jq msmtp`
- **Fedora / RHEL**: `sudo dnf install git curl jq msmtp`
- **Alpine**: `apk add bash git curl jq msmtp`

---

## Token Creation

### GitHub Token (Read-Only)

Navigate to: **GitHub → Settings → Developer settings → Personal access tokens**.

- **Option A — Fine-grained token (recommended)**:
  - *Repository access*: **All repositories** (or select specific ones).
  - *Permissions*: **Contents**: `Read-only`, **Metadata**: `Read-only`.
- **Option B — Classic token**:
  - Select `repo` (full control of private repositories) and optionally `read:org` if you mirror organization repositories.

### GitLab Token

Navigate to: **GitLab → Preferences / User Settings → Access Tokens**.

- Name: `github-mirror`
- Scopes: **`write_repository`** (grants permissions to push code and create projects via push-to-create; no API access required). All mirrored repositories are created as **private**.

---

## Quick Start

### 1. Clone & Setup

```bash
git clone <this-repo> github-gitlab-mirror
cd github-gitlab-mirror

# Run the interactive setup wizard
./setup.sh
```

The setup script checks dependencies, sets up `.env` with strict permissions (`600`), validates your tokens against the GitHub and GitLab APIs, and can configure daily automation (systemd user timer or cron).

<details>
<summary>Manual configuration</summary>

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and fill in your credentials (usernames are auto-detected from tokens if omitted):

```bash
GITHUB_TOKEN="ghp_your_github_token"
GITLAB_TOKEN="glpat_your_gitlab_token"
```

</details>

### 2. Test Run

```bash
# Preview what would be mirrored without making any changes
./mirror.sh --dry-run

# List all matching repositories
./mirror.sh --list

# Mirror a single repository to test
./mirror.sh --repo your-user/test-repo

# Run full mirror
./mirror.sh
```

Mirrored repositories are stored in `./data/repos/` by default. Logging streams to stdout / journalctl (file logging disabled by default; set `LOG_DIR="./logs"` in `.env` if desired).

---

## Configuration Reference

| Variable | Description | Default |
|---|---|---|
| `GITHUB_USER` | GitHub username | Auto-detected from `GITHUB_TOKEN` |
| `GITHUB_TOKEN` | GitHub personal access token | *(Required)* |
| `GITHUB_API_URL` | GitHub API endpoint | `https://api.github.com` |
| `GITHUB_ORGS` | Space-separated list of organizations to mirror | `""` |
| `GITHUB_INCLUDE_FORKS` | Mirror forked repositories (`true` / `false`) | `false` |
| `GITHUB_INCLUDE_ARCHIVED` | Mirror archived repositories (`true` / `false`) | `false` |
| `GITHUB_EXCLUDE` | Space-separated patterns or globs to skip | `""` |
| `GITLAB_USER` | GitLab username | Defaults to `GITHUB_USER` if omitted |
| `GITLAB_TOKEN` | GitLab access token (`write_repository` scope) | *(Required)* |
| `GITLAB_HOST` | GitLab instance URL | `https://gitlab.com` |
| `GITLAB_GROUP` | Target group/subgroup path | `""` (personal namespace) |
| `MIRROR_DIR` | Directory to store bare git clones | `./data/repos` |
| `LOG_DIR` | Directory to store log files (empty = disabled, stdout only) | `""` (disabled) |
| `GIT_PROTOCOL` | Git transport (`https` or `ssh`) | `https` |
| `PUSH_ALWAYS` | Push even if GitHub has not changed | `true` |
| `DRY_RUN` | Preview mode without modifying remotes | `false` |
| `EMAIL_NOTIFY` | Enable email reports on failure | `false` |
| `EMAIL_TO` | Email recipient | `""` |
| `EMAIL_FROM` | Email sender address | Hostname |
| `EMAIL_ON_SUCCESS` | Also send email when run succeeds without error | `false` |
| `WEBHOOK_URL` | Incoming webhook URL (Slack, Discord, Mattermost) | `""` |

---

## CLI Options

```text
Usage:
  mirror.sh                 Mirror all configured repositories
  mirror.sh --repo SLUG     Mirror only a single repository ("owner/repo")
  mirror.sh --list          List discovered repositories without touching anything
  mirror.sh --dry-run       Preview actions without cloning or pushing
  mirror.sh --skip-archived Skip archived repositories (default)
  mirror.sh --include-archived Include archived repositories
  mirror.sh --help          Show help text
```

To specify an alternative configuration file:
```bash
ENV_FILE=/path/to/custom.env ./mirror.sh
```

---

## Scheduling

### Option A: systemd User Timer (Linux, no root needed)

To run daily as your standard user:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/github-mirror.service ~/.config/systemd/user/
cp systemd/github-mirror.timer ~/.config/systemd/user/

# Adjust paths in ~/.config/systemd/user/github-mirror.service if needed:
# WorkingDirectory=%h/github-gitlab-mirror
# ExecStart=%h/github-gitlab-mirror/mirror.sh
# EnvironmentFile=-%h/github-gitlab-mirror/.env

systemctl --user daemon-reload
systemctl --user enable --now github-mirror.timer
```

Check status:
```bash
systemctl --user list-timers
systemctl --user status github-mirror.service
```

### Option B: Cron (macOS / Linux / BSD)

Edit your user crontab:

```bash
crontab -e
```

Add a daily job at 03:00:

```cron
0 3 * * * /path/to/github-gitlab-mirror/mirror.sh >/dev/null 2>&1
```

---

## Notifications

### Email (`msmtp` / `sendmail`)

When `EMAIL_NOTIFY="true"`, failures generate a report with run statistics and recent log lines:

```bash
EMAIL_NOTIFY="true"
EMAIL_TO="alerts@example.com"
```

Example `~/.msmtprc` configuration for `msmtp`:

```ini
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        default
host           smtp.example.com
port           587
from           alerts@example.com
user           alerts@example.com
password       "secret-password"
```

Set permissions:
```bash
chmod 600 ~/.msmtprc
```

### Webhooks

To notify Slack, Discord, or Mattermost, set `WEBHOOK_URL` in `.env`:
```bash
WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

---

## Excluding Repositories

Add patterns to `GITHUB_EXCLUDE` in `.env`. Patterns match repo slugs, repo names, or globs:

```bash
GITHUB_EXCLUDE="test-* scratch-pad owner/private-experiments"
```

---

## SSH Authentication (Optional)

By default, HTTPS authentication is used with your tokens. If you prefer SSH keys:

1. Set `GIT_PROTOCOL="ssh"` in `.env`.
2. Generate an SSH key:
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519_mirror
```
3. Add the public key to both GitHub (**Settings → SSH keys**) and GitLab (**Preferences → SSH Keys**).
4. Configure SSH host keys:
```bash
ssh-keyscan github.com gitlab.com >> ~/.ssh/known_hosts
```

---

## Maintenance & Storage

- Bare clones are stored inside `./data/repos/<owner>/<repo>.git`.
- Periodically prune old git loose objects to save space:
```bash
find ./data/repos -name '*.git' -exec git -C {} gc --prune=now \;
```
- If `LOG_DIR` is set in `.env`, daily logs are saved to `${LOG_DIR}/mirror-YYYYMMDD.log` with a symlink at `latest.log`.
