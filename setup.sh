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

install_packages() {
  local pkgs=("$@")
  if [ "$(uname -s)" = "Darwin" ]; then
    brew install "${pkgs[@]}"
  elif [ -f /etc/debian_version ]; then
    sudo apt update && sudo apt install -y "${pkgs[@]}"
  elif [ -f /etc/arch-release ]; then
    sudo pacman -S --noconfirm "${pkgs[@]}"
  elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    sudo dnf install -y "${pkgs[@]}"
  elif [ -f /etc/alpine-release ]; then
    apk add "${pkgs[@]}"
  else
    return 1
  fi
}

show_manual_install_cmd() {
  local pkgs=("$@")
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "  brew install ${pkgs[*]}"
  elif [ -f /etc/debian_version ]; then
    echo "  sudo apt update && sudo apt install -y ${pkgs[*]}"
  elif [ -f /etc/arch-release ]; then
    echo "  sudo pacman -S --noconfirm ${pkgs[*]}"
  elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    echo "  sudo dnf install -y ${pkgs[*]}"
  elif [ -f /etc/alpine-release ]; then
    echo "  apk add ${pkgs[*]}"
  else
    echo "  Install using your system package manager: ${pkgs[*]}"
  fi
}

if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
  echo
  warn "Missing required tool(s): ${MISSING_DEPS[*]}"
  if [ "$INTERACTIVE" = true ]; then
    read -r -p "Do you want to install missing required dependencies now? [Y/n]: " INSTALL_DEPS || INSTALL_DEPS="n"
    if [[ ! "$INSTALL_DEPS" =~ ^[Nn]$ ]]; then
      info "Installing ${MISSING_DEPS[*]}..."
      install_packages "${MISSING_DEPS[@]}" || true

      STILL_MISSING=()
      for cmd in "${MISSING_DEPS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
          STILL_MISSING+=("$cmd")
        fi
      done

      if [ "${#STILL_MISSING[@]}" -eq 0 ]; then
        success "Dependencies installed successfully!"
      else
        error "Could not automatically install: ${STILL_MISSING[*]}"
        echo "Please install them manually:"
        show_manual_install_cmd "${STILL_MISSING[@]}"
        exit 1
      fi
    else
      error "Cannot proceed without required dependencies: ${MISSING_DEPS[*]}"
      echo "To continue setup later, install them manually:"
      show_manual_install_cmd "${MISSING_DEPS[@]}"
      exit 1
    fi
  else
    error "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo "Please install them first:"
    show_manual_install_cmd "${MISSING_DEPS[@]}"
    exit 1
  fi
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
      install_packages msmtp || true

      if command -v msmtp >/dev/null 2>&1; then
        success "msmtp installed successfully!"
        HAS_MSMTP=true
      else
        warn "Could not install msmtp automatically. You can install it manually later:"
        show_manual_install_cmd msmtp
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

  # GitLab user
  read -r -p "GitLab Username (optional, press Enter to use same as GitHub): " INPUT_GL_USER || INPUT_GL_USER=""
  if [ -n "$INPUT_GL_USER" ]; then
    sed -i.bak -e "s|^#* *GITLAB_USER=.*|GITLAB_USER=\"$INPUT_GL_USER\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  fi

  # GitLab token
  read -r -p "GitLab Token (glpat_... with 'write_repository' scope): " INPUT_GL_TOKEN || INPUT_GL_TOKEN=""
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
          echo
          read -r -p "~/.msmtprc not found. Would you like to configure it now? [Y/n]: " CONFIGURE_MSMTPRC || CONFIGURE_MSMTPRC="y"
          if [[ ! "$CONFIGURE_MSMTPRC" =~ ^[Nn]$ ]]; then
            default_host="smtp.gmail.com"
            read -r -p "SMTP Host [default: $default_host]: " MSMTP_HOST || MSMTP_HOST=""
            MSMTP_HOST="${MSMTP_HOST:-$default_host}"

            read -r -p "SMTP Port [default: 587]: " MSMTP_PORT || MSMTP_PORT=""
            MSMTP_PORT="${MSMTP_PORT:-587}"

            read -r -p "SMTP Username / Sender email [default: $INPUT_EMAIL_TO]: " MSMTP_USER || MSMTP_USER=""
            MSMTP_USER="${MSMTP_USER:-$INPUT_EMAIL_TO}"

            echo "Note: For Gmail, Outlook, or iCloud, use an App Password, not your main account password."
            read -r -s -p "SMTP Password / App Password: " MSMTP_PASS || MSMTP_PASS=""
            echo

            if [ -n "$MSMTP_PASS" ]; then
              cat > "$HOME/.msmtprc" <<EOF
defaults
auth           on
tls            on
logfile        ~/.msmtp.log

account        default
host           $MSMTP_HOST
port           $MSMTP_PORT
tls_starttls   on
from           $MSMTP_USER
user           $MSMTP_USER
password       "$MSMTP_PASS"
EOF
              chmod 600 "$HOME/.msmtprc"
              success "~/.msmtprc configured and permissions set to 600!"
              sed -i.bak -e "s|^EMAIL_FROM=.*|EMAIL_FROM=\"$MSMTP_USER\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"

              read -r -p "Send a test email to $INPUT_EMAIL_TO now? [Y/n]: " TEST_EMAIL || TEST_EMAIL="y"
              if [[ ! "$TEST_EMAIL" =~ ^[Nn]$ ]]; then
                info "Sending test email..."
                if EMAIL_TO="$INPUT_EMAIL_TO" EMAIL_FROM="$MSMTP_USER" EMAIL_SUBJECT="[GitHub Mirror] Test notification" "$SCRIPT_DIR/notify.sh" <<< "This is a test notification from GitHub -> GitLab Mirror setup." >/dev/null 2>&1; then
                  success "Test email sent successfully! Check your inbox."
                else
                  warn "Failed to send test email. Check ~/.msmtprc and ~/.msmtp.log for details."
                fi
              fi
            else
              warn "Password was left empty. ~/.msmtprc was not created (see README.md)."
            fi
          else
            info "Remember to create your ~/.msmtprc manually (see README.md)."
          fi
        else
          success "Found existing ~/.msmtprc"
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
GL_USER="${GITLAB_USER:-}"
GL_GROUP="${GITLAB_GROUP:-}"

DETECTED_GH=""
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
  TARGET_NS="${GL_GROUP:-${GL_USER:-${DETECTED_GH:-personal}}}"
  success "GitLab token configured (target namespace: ${BOLD}${TARGET_NS}${RESET})"
else
  warn "GitLab token is not configured yet. Set GITLAB_TOKEN in .env"
fi

# ---------------------------------------------------------------------------
# 4. Scheduling options (systemd vs cron)
# ---------------------------------------------------------------------------
echo
info "Scheduling configuration..."

HAS_SYSTEMD=false
if command -v systemctl >/dev/null 2>&1; then
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

        if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
          export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        fi

        if systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now github-mirror.timer 2>/dev/null; then
          success "systemd user timer enabled and active!"
          info "Check status anytime with: systemctl --user list-timers github-mirror.timer"
          if command -v loginctl >/dev/null 2>&1; then
            loginctl enable-linger "$USER" 2>/dev/null || true
          fi
        else
          warn "Unit files installed to $USER_SYSTEMD_DIR, but 'systemctl --user' could not reach D-Bus."
          echo "  Run these commands to activate manually:"
          echo "    export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
          echo "    systemctl --user daemon-reload"
          echo "    systemctl --user enable --now github-mirror.timer"
          echo "    loginctl enable-linger \$USER"
        fi
      else
        warn "systemctl is not available on this system."
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
