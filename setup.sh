#!/usr/bin/env bash
# =============================================================================
# setup.sh — Setup and installer wizard for GitHub → GitLab Mirror
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Flags
INTERACTIVE=true
if [ ! -t 0 ] || [ "${1:-}" = "-y" ] || [ "${1:-}" = "--non-interactive" ]; then
  INTERACTIVE=false
fi

# Colors
if [ -t 1 ]; then
  BOLD="\033[1m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" YELLOW="" BLUE="" RED="" RESET=""
fi

info()    { printf "${BLUE}${BOLD}==>${RESET} %s\n" "$*"; }
success() { printf "${GREEN}${BOLD}✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}${BOLD}!${RESET} %s\n" "$*"; }
error()   { printf "${RED}${BOLD}✗${RESET} %s\n" "$*" >&2; }

echo
printf "${BOLD}======================================================${RESET}\n"
printf "${BOLD}        GitHub → GitLab Mirror Setup & Install       ${RESET}\n"
printf "${BOLD}======================================================${RESET}\n"
echo

# ---------------------------------------------------------------------------
# 1. Dependency checks & optional installations
# ---------------------------------------------------------------------------
info "Checking dependencies..."
MISSING_DEPS=()
for cmd in git curl jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    success "Found $cmd"
  else
    error "Missing required tool: $cmd"
    MISSING_DEPS+=("$cmd")
  fi
done

if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
  echo
  error "Please install missing required dependencies first:"
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "  brew install ${MISSING_DEPS[*]}"
  elif [ -f /etc/debian_version ]; then
    echo "  sudo apt update && sudo apt install -y ${MISSING_DEPS[*]}"
  elif [ -f /etc/arch-release ]; then
    echo "  sudo pacman -S --noconfirm ${MISSING_DEPS[*]}"
  elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    echo "  sudo dnf install -y ${MISSING_DEPS[*]}"
  elif [ -f /etc/alpine-release ]; then
    echo "  apk add ${MISSING_DEPS[*]}"
  else
    echo "  Install using your system package manager: ${MISSING_DEPS[*]}"
  fi
  exit 1
fi

# Check msmtp (optional email tool)
HAS_MSMTP=false
if command -v msmtp >/dev/null 2>&1; then
  success "Found msmtp (email support available)"
  HAS_MSMTP=true
else
  warn "msmtp not found (needed for email alerts)"
  if [ "$INTERACTIVE" = true ]; then
    read -r -p "Do you want to install msmtp now? [y/N]: " INSTALL_MSMTP || INSTALL_MSMTP="n"
    if [[ "$INSTALL_MSMTP" =~ ^[Yy]$ ]]; then
      info "Installing msmtp..."
      if [ "$(uname -s)" = "Darwin" ]; then
        brew install msmtp || true
      elif [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y msmtp || true
      elif [ -f /etc/arch-release ]; then
        sudo pacman -S --noconfirm msmtp || true
      elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
        sudo dnf install -y msmtp || true
      elif [ -f /etc/alpine-release ]; then
        apk add msmtp || true
      fi

      if command -v msmtp >/dev/null 2>&1; then
        success "msmtp installed successfully!"
        HAS_MSMTP=true
      else
        warn "Could not install msmtp automatically. You can install it manually later."
      fi
    fi
  fi
fi

echo
# ---------------------------------------------------------------------------
# 2. Configure .env
# ---------------------------------------------------------------------------
info "Configuring environment (.env)..."
ENV_FILE="$SCRIPT_DIR/.env"

RECONFIGURE=false
if [ ! -f "$ENV_FILE" ]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  success "Created .env from .env.example (permissions: 600)"
  RECONFIGURE=true
else
  warn ".env file already exists."
  if [ "$INTERACTIVE" = true ]; then
    read -r -p "Do you want to reconfigure credentials? [y/N]: " REPLY || REPLY="n"
    [[ "$REPLY" =~ ^[Yy]$ ]] && RECONFIGURE=true
  fi
fi

if [ "$INTERACTIVE" = true ] && [ "$RECONFIGURE" = true ]; then
  echo
  printf "Enter your credentials (press Enter to skip/keep unchanged):\n\n"

  # GitHub token
  read -r -p "GitHub Token (ghp_...): " INPUT_GH_TOKEN || INPUT_GH_TOKEN=""
  if [ -n "$INPUT_GH_TOKEN" ]; then
    sed -i.bak -e "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=\"$INPUT_GH_TOKEN\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  fi

  # GitLab token
  read -r -p "GitLab Token (glpat_...): " INPUT_GL_TOKEN || INPUT_GL_TOKEN=""
  if [ -n "$INPUT_GL_TOKEN" ]; then
    sed -i.bak -e "s|^GITLAB_TOKEN=.*|GITLAB_TOKEN=\"$INPUT_GL_TOKEN\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  fi

  # Optional GitLab Group
  read -r -p "GitLab Group/Subgroup namespace (optional, press Enter for personal): " INPUT_GL_GROUP || INPUT_GL_GROUP=""
  if [ -n "$INPUT_GL_GROUP" ]; then
    sed -i.bak -e "s|^GITLAB_GROUP=.*|GITLAB_GROUP=\"$INPUT_GL_GROUP\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  fi

  # Optional Email configuration if msmtp is present
  if [ "$HAS_MSMTP" = true ] || command -v msmtp >/dev/null 2>&1; then
    echo
    read -r -p "Configure email failure notifications? [y/N]: " CONFIGURE_EMAIL || CONFIGURE_EMAIL="n"
    if [[ "$CONFIGURE_EMAIL" =~ ^[Yy]$ ]]; then
      read -r -p "Recipient email address (EMAIL_TO): " INPUT_EMAIL_TO || INPUT_EMAIL_TO=""
      if [ -n "$INPUT_EMAIL_TO" ]; then
        sed -i.bak -e "s|^EMAIL_NOTIFY=.*|EMAIL_NOTIFY=\"true\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
        sed -i.bak -e "s|^EMAIL_TO=.*|EMAIL_TO=\"$INPUT_EMAIL_TO\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
        success "Email notifications enabled for: $INPUT_EMAIL_TO"
        if [ ! -f "$HOME/.msmtprc" ]; then
          info "Note: ~/.msmtprc not found. Remember to create your ~/.msmtprc (see README.md)."
        fi
      fi
    fi
  fi
fi

chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# 3. Validate credentials and connection
# ---------------------------------------------------------------------------
echo
info "Validating credentials..."
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

GH_TOKEN="${GITHUB_TOKEN:-}"
GL_TOKEN="${GITLAB_TOKEN:-}"
GL_HOST="${GITLAB_HOST:-https://gitlab.com}"
GL_HOST="${GL_HOST%/}"

if [ -n "$GH_TOKEN" ] && [ "$GH_TOKEN" != "ghp_your_github_token" ] && [[ ! "$GH_TOKEN" =~ xxxxx ]]; then
  DETECTED_GH="$(curl -fsS -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}/user" 2>/dev/null | jq -r '.login // empty' || true)"
  if [ -n "$DETECTED_GH" ]; then
    success "GitHub token valid! Connected as: ${BOLD}$DETECTED_GH${RESET}"
  else
    warn "Could not verify GitHub token. Check token permissions."
  fi
else
  warn "GitHub token is not configured yet. Set GITHUB_TOKEN in .env"
fi

if [ -n "$GL_TOKEN" ] && [ "$GL_TOKEN" != "glpat_your_gitlab_token" ] && [[ ! "$GL_TOKEN" =~ xxxxx ]]; then
  DETECTED_GL="$(curl -fsS -H "PRIVATE-TOKEN: ${GL_TOKEN}" \
    "${GL_HOST}/api/v4/user" 2>/dev/null | jq -r '.username // empty' || true)"
  if [ -n "$DETECTED_GL" ]; then
    success "GitLab token valid! Connected as: ${BOLD}$DETECTED_GL${RESET}"
  else
    warn "Could not verify GitLab token. Check token permissions."
  fi
else
  warn "GitLab token is not configured yet. Set GITLAB_TOKEN in .env"
fi

# ---------------------------------------------------------------------------
# 4. Scheduling options (systemd vs cron)
# ---------------------------------------------------------------------------
echo
info "Scheduling configuration..."

HAS_SYSTEMD=false
if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
  HAS_SYSTEMD=true
fi

CRON_CMD="0 3 * * * $SCRIPT_DIR/mirror.sh >/dev/null 2>&1"

if [ "$INTERACTIVE" = true ]; then
  echo "How would you like to schedule the daily mirror (03:00)?"
  echo "  1) systemd (user timer, recommended on Linux)"
  echo "  2) cron (crontab entry, macOS/Linux/BSD)"
  echo "  3) none (skip automatic scheduling)"
  read -r -p "Select option [1/2/3, default: 3]: " SCHED_CHOICE || SCHED_CHOICE="3"

  case "$SCHED_CHOICE" in
    1|systemd)
      if [ "$HAS_SYSTEMD" = true ]; then
        USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
        mkdir -p "$USER_SYSTEMD_DIR"

        # Generate custom service file with exact current directory
        sed \
          -e "s|%h/gitlab-mirror-gist|$SCRIPT_DIR|g" \
          "$SCRIPT_DIR/systemd/github-mirror.service" > "$USER_SYSTEMD_DIR/github-mirror.service"

        cp "$SCRIPT_DIR/systemd/github-mirror.timer" "$USER_SYSTEMD_DIR/github-mirror.timer"

        systemctl --user daemon-reload
        systemctl --user enable --now github-mirror.timer
        success "systemd user timer enabled and active!"
        info "Check status anytime with: systemctl --user list-timers github-mirror.timer"
      else
        warn "systemd user session is not available on this system."
        read -r -p "Fall back to cron? [Y/n]: " CRON_FALLBACK || CRON_FALLBACK="y"
        if [[ ! "$CRON_FALLBACK" =~ ^[Nn]$ ]]; then
          SCHED_CHOICE="2"
        fi
      fi
      ;;
  esac

  if [ "$SCHED_CHOICE" = "2" ] || [ "$SCHED_CHOICE" = "cron" ]; then
    read -r -p "Automatically add daily job to your crontab? [Y/n]: " ADD_CRON || ADD_CRON="y"
    if [[ ! "$ADD_CRON" =~ ^[Nn]$ ]]; then
      CURRENT_CRON="$(crontab -l 2>/dev/null || true)"
      if echo "$CURRENT_CRON" | grep -Fq "$SCRIPT_DIR/mirror.sh"; then
        warn "Crontab already contains an entry for mirror.sh"
      else
        printf "%s\n%s\n" "$CURRENT_CRON" "$CRON_CMD" | grep -v '^$' | crontab -
        success "Added daily job to crontab (runs at 03:00)!"
      fi
    else
      info "Add manually to your crontab (crontab -e):"
      echo "  $CRON_CMD"
    fi
  fi
else
  info "Non-interactive mode: skipping scheduling. Cron suggestion:"
  echo "  $CRON_CMD"
fi

# ---------------------------------------------------------------------------
# 5. Test run prompt
# ---------------------------------------------------------------------------
if [ "$INTERACTIVE" = true ]; then
  echo
  read -r -p "Do you want to run a dry-run test now? [y/N]: " RUN_DRY || RUN_DRY="n"
  if [[ "$RUN_DRY" =~ ^[Yy]$ ]]; then
    echo
    info "Running: ./mirror.sh --dry-run"
    "$SCRIPT_DIR/mirror.sh" --dry-run || true
  fi
fi

echo
success "Setup complete! You can run './mirror.sh' at any time."
echo
