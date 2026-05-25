#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "[INFO] $*"; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

# Backup helper (idempotent)
backup_file() {
  local f="$1"
  if [ -f "$f" ] && [ ! -f "${f}.uv_policy_bak" ]; then
    cp "$f" "${f}.uv_policy_bak"
    log "Backup created: ${f}.uv_policy_bak"
  fi
}

# Install libpam-pwquality on Debian-based systems
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y libpam-pwquality || log "libpam-pwquality install failed, continuing"
fi

# PAM common-password
CPP="/etc/pam.d/common-password"
if [ -f "$CPP" ]; then
  backup_file "$CPP"
  # Insert pam_pwquality if missing (before pam_unix.so)
  if ! grep -q 'pam_pwquality.so' "$CPP"; then
    awk '/pam_unix.so/{print "password requisite pam_pwquality.so retry=3 minlen=12 difok=3"; print; next}1' "$CPP" > "$CPP.tmp" && mv "$CPP.tmp" "$CPP"
    log "Inserted pam_pwquality line into $CPP"
  else
    log "pam_pwquality already present in $CPP"
  fi

  # Ensure pam_unix has remember=5
  if grep -q 'pam_unix.so' "$CPP"; then
    if grep -q 'pam_unix.so.*remember=' "$CPP"; then
      sed -r -i 's/(pam_unix.so[^\n]*?)remember=[0-9]+/\1remember=5/' "$CPP" || true
    else
      sed -i '/pam_unix.so/ s/$/ remember=5/' "$CPP" || true
    fi
    log "Ensured pam_unix has remember=5"
  fi
else
  log "$CPP not found; skipping PAM changes"
fi

# login.defs
LD="/etc/login.defs"
if [ -f "$LD" ]; then
  backup_file "$LD"
  sed -i '/^PASS_MAX_DAYS/ d' "$LD"
  sed -i '/^PASS_MIN_DAYS/ d' "$LD"
  sed -i '/^PASS_WARN_AGE/ d' "$LD"
  echo "PASS_MAX_DAYS 90" >> "$LD"
  echo "PASS_MIN_DAYS 7" >> "$LD"
  echo "PASS_WARN_AGE 14" >> "$LD"
  log "Updated $LD with password aging policy"
else
  log "$LD not found; skipping login.defs changes"
fi

# Apply chage for uv_* users
for u in uv_admin uv_webmaster uv_dbadmin; do
  if id "$u" >/dev/null 2>&1; then
    chage -M 90 -m 7 -W 14 "$u" || log "chage failed for $u"
    log "Password aging set for $u"
  else
    log "User $u not present, skipping"
  fi
done

log "Password policy applied."

exit 0
