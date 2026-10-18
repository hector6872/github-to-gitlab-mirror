#!/usr/bin/env bash
#
# notify.sh — sends the body received on STDIN as an email.
#
# Environment variables:
#   EMAIL_SUBJECT   Email subject.
#   EMAIL_TO        Recipient (required; if empty, nothing is sent).
#   EMAIL_FROM      Sender.
#   MSMTP_CONFIG    Path to an msmtp configuration file (optional).
#   MSMTP_ACCOUNT   msmtp account to use (optional).
#
# Transport preference order: msmtp -> sendmail -> mail.
#
set -uo pipefail

subject="${EMAIL_SUBJECT:-[GitHub Mirror]}"
to="${EMAIL_TO:-}"
from="${EMAIL_FROM:-$(hostname 2>/dev/null || echo 'localhost')}"
msmtp_config="${MSMTP_CONFIG:-}"
msmtp_account="${MSMTP_ACCOUNT:-}"

if [ -z "$to" ]; then
  echo "notify.sh: EMAIL_TO is empty, nothing to send" >&2
  exit 0
fi

body="$(cat)"

message="From: ${from}
To: ${to}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
X-Mailer: github-gitlab-mirror

${body}"

if command -v msmtp >/dev/null 2>&1; then
  args=()
  [ -n "$msmtp_config" ] && [ -f "$msmtp_config" ] && args+=(--file "$msmtp_config")
  [ -n "$msmtp_account" ] && args+=(--account "$msmtp_account")
  if printf '%s' "$message" | msmtp "${args[@]}" "$to"; then
    echo "notify.sh: email sent to $to via msmtp"
    exit 0
  fi
  echo "notify.sh: msmtp failed, trying another transport" >&2
fi

if command -v sendmail >/dev/null 2>&1; then
  if printf '%s' "$message" | sendmail -t; then
    echo "notify.sh: email sent via sendmail"
    exit 0
  fi
fi

if command -v mail >/dev/null 2>&1; then
  if printf '%s' "$body" | mail -s "$subject" "$to"; then
    echo "notify.sh: email sent via mail"
    exit 0
  fi
fi

echo "notify.sh: no mail transport found (msmtp/sendmail/mail)" >&2
exit 1
