# GitHub → GitLab Mirror

A lightweight, system-agnostic script that mirrors **every repository of a GitHub account** (and optional organizations) into **GitLab** (all branches + tags). It detects remote changes, repairs drift, optionally auto-creates missing GitLab projects, and can notify you via email or webhook when errors occur.

Runs anywhere: **macOS, any Linux distribution, Raspberry Pi, VPS, or containers**. It requires **no root permissions**, no browser, and no heavy runtime dependencies.

---

## Highlights

- **Agnostic & Lightweight**: Runs in-place with no root/`sudo` required. Only needs `bash`, `git`, `curl`, and `jq`.
- **Environment-based Configuration**: Put settings into a `.env` file or provide ambient environment variables. No copying to `/etc` or `/opt`.
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

Package manager install commands:
- **macOS (Homebrew)**: `brew install git curl jq`
- **Debian / Ubuntu / Raspberry Pi OS**: `sudo apt install git curl jq`
- **Arch Linux**: `sudo pacman -S git curl jq`
- **Fedora / RHEL**: `sudo dnf install git curl jq`
- **Alpine**: `apk add bash git curl jq`

---

## Quick Start

### 1. Clone & Configure

```bash
git clone <this-repo> github-gitlab-mirror
cd github-gitlab-mirror

# Create your .env file
cp .env.example .env
chmod 600 .env
```

Edit `.env` and fill in your credentials:

```bash
GITHUB_USER="your-github-user"
GITHUB_TOKEN="ghp_your_github_token"
GITLAB_USER="your-gitlab-user"
GITLAB_TOKEN="glpat_your_gitlab_token"
```

> **Token scopes**:
> - **GitHub**: Personal Access Token (classic `repo`, or fine-grained `Contents: Read-only` & `Metadata: Read-only`).
> - **GitLab**: Personal Access Token with the `api` scope (required for project creation and push).

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

## CLI Options

```text
Usage:
  mirror.sh                 Mirror all configured repositories
  mirror.sh --repo SLUG     Mirror only a single repository ("owner/repo")
  mirror.sh --list          List discovered repositories without touching anything
  mirror.sh --dry-run       Preview actions without cloning or pushing
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

When `EMAIL_NOTIFY="true"`, failures generate a report with run statistics and recent log lines.
Configure `EMAIL_TO` and `EMAIL_FROM` in `.env`. The script automatically uses `msmtp`, `sendmail`, or `mail` if present.

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

## Project Structure

```text
.
├── .env.example              # Configuration template
├── .gitignore
├── mirror.sh                 # Main mirror script
├── notify.sh                 # Email notification helper
├── systemd/
│   ├── github-mirror.service # systemd user/system service template
│   └── github-mirror.timer   # Daily 03:00 timer template
├── docs/
│   └── SETUP.md              # Token creation & advanced setup guide
└── README.md
```
