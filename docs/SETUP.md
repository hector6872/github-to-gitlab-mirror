# Setup & Reference Guide

A complete guide for configuring tokens, scheduling, notifications, and permissions on any operating system (Linux, macOS, BSD, containers).

---

## 1. System Requirements

Ensure the base dependencies are installed:

- `git` (v2.20+)
- `curl`
- `jq`
- Optional: `msmtp` or `sendmail` (for email notifications)

Install examples by platform:
- **macOS**: `brew install git curl jq msmtp`
- **Debian / Ubuntu / Raspberry Pi**: `sudo apt install git curl jq msmtp`
- **Arch Linux**: `sudo pacman -S git curl jq msmtp`
- **Fedora / RHEL**: `sudo dnf install git curl jq msmtp`
- **Alpine Linux**: `apk add bash git curl jq msmtp`

No browser, webdriver, or heavy runtime is required.

---

## 2. Token Creation

### GitHub Token (Read-Only)

Navigate to: **GitHub → Settings → Developer settings → Personal access tokens**.

**Option A — Fine-grained token (recommended):**
- *Repository access*: **All repositories** (or select specific ones).
- *Permissions*:
  - **Contents**: `Read-only`
  - **Metadata**: `Read-only`
- Generate token and copy the value.

**Option B — Classic token:**
- Select `repo` (full control of private repositories) and optionally `read:org` if you mirror organization repositories.
- Generate token and copy the value (`ghp_...`).

### GitLab Token

Navigate to: **GitLab → Preferences / User Settings → Access Tokens**.

- Name: `github-mirror`
- Scopes: **`api`** (grants permissions to query APIs, create projects, and push commits/tags).
- Generate token and copy the value (`glpat_...`).

> **Note on GitLab Groups**: If mirroring into a group namespace (`GITLAB_GROUP`), the token holder must have permissions to create projects in that group (Developer role or higher).

---

## 3. Configuration with `.env`

Copy the template file to `.env` in the repository root:

```bash
cp .env.example .env
chmod 600 .env
```

Open `.env` in your text editor and specify your credentials:

```bash
GITHUB_USER="your-github-user"
GITHUB_TOKEN="ghp_your_github_token"
GITLAB_USER="your-gitlab-user"
GITLAB_TOKEN="glpat_your_gitlab_token"
```

### Configuration Variables Reference

| Variable | Description | Default |
|---|---|---|
| `GITHUB_USER` | GitHub username | *(Required)* |
| `GITHUB_TOKEN` | GitHub personal access token | *(Required)* |
| `GITHUB_API_URL` | GitHub API endpoint | `https://api.github.com` |
| `GITHUB_ORGS` | Space-separated list of organizations to mirror | `""` |
| `GITHUB_INCLUDE_FORKS` | Mirror forked repositories (`true` / `false`) | `false` |
| `GITHUB_INCLUDE_ARCHIVED` | Mirror archived repositories (`true` / `false`) | `true` |
| `GITHUB_EXCLUDE` | Space-separated patterns or globs to skip | `""` |
| `GITLAB_USER` | GitLab username | *(Required)* |
| `GITLAB_TOKEN` | GitLab access token | *(Required)* |
| `GITLAB_HOST` | GitLab instance URL | `https://gitlab.com` |
| `GITLAB_GROUP` | Target group/subgroup path | `""` (personal namespace) |
| `GITLAB_VISIBILITY` | Visibility for created repos (`private`, `internal`, `public`) | `private` |
| `GITLAB_AUTO_CREATE` | Auto-create repository on GitLab if missing | `true` |
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

## 4. Testing

Verify your setup with safe commands:

```bash
# 1. Preview matching repos and planned remote operations
./mirror.sh --dry-run

# 2. Print list of repository slugs discovered from GitHub
./mirror.sh --list

# 3. Test with a single repository
./mirror.sh --repo your-github-user/my-test-repo

# 4. Run the full mirror
./mirror.sh
```

---

## 5. Scheduling Automation

### Option 1: systemd User Timer (Linux, non-root)

If your system runs systemd, you can run the mirror under your regular user account:

1. Copy the systemd unit templates:
```bash
mkdir -p ~/.config/systemd/user
cp systemd/github-mirror.service ~/.config/systemd/user/
cp systemd/github-mirror.timer ~/.config/systemd/user/
```

2. Verify paths in `~/.config/systemd/user/github-mirror.service`:
```ini
WorkingDirectory=%h/gitlab-mirror-gist
ExecStart=%h/gitlab-mirror-gist/mirror.sh
EnvironmentFile=-%h/gitlab-mirror-gist/.env
```

3. Enable and start the timer:
```bash
systemctl --user daemon-reload
systemctl --user enable --now github-mirror.timer
```

4. View status:
```bash
systemctl --user list-timers github-mirror.timer
journalctl --user -u github-mirror.service -n 50 --no-pager
```

### Option 2: Cron (macOS / Linux / BSD)

Open your user crontab:
```bash
crontab -e
```

Add an entry to trigger daily at 3:00 AM:
```cron
0 3 * * * /absolute/path/to/gitlab-mirror-gist/mirror.sh >/dev/null 2>&1
```

---

## 6. Email Setup (`msmtp`)

If you want email alerts on failures:

1. Enable email in `.env`:
```bash
EMAIL_NOTIFY="true"
EMAIL_TO="alerts@example.com"
```

2. Create an `msmtp` configuration in `~/.msmtprc` (or `/etc/msmtprc`):

```ini
# ~/.msmtprc
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

3. Restrict permissions:
```bash
chmod 600 ~/.msmtprc
```

Test sending manually:
```bash
echo "Test notification" | ./notify.sh
```

---

## 7. SSH Authentication (Optional)

By default, HTTPS authentication is used with your tokens. If you prefer SSH keys:

1. Set `GIT_PROTOCOL="ssh"` in `.env`.
2. Generate an SSH key (or use your existing key `~/.ssh/id_ed25519`):
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519_mirror
```
3. Add the public key to both GitHub (**Settings → SSH keys**) and GitLab (**Preferences → SSH Keys**).
4. Configure SSH host keys:
```bash
ssh-keyscan github.com gitlab.com >> ~/.ssh/known_hosts
```

---

## 8. Maintenance & Storage

- Bare clones are stored inside `./data/repos/<owner>/<repo>.git`.
- You can optimize and prune old git loose objects periodically:
```bash
find ./data/repos -name '*.git' -exec git -C {} gc --prune=now \;
```
- If `LOG_DIR` is set in `.env`, daily logs are saved to `${LOG_DIR}/mirror-YYYYMMDD.log` with a symlink at `latest.log`.
