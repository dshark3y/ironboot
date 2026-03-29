#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.4.1"

VERBOSE=0
DRY_RUN=0
ONLY_STEPS=""
SKIP_STEPS=""
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/vps-bootstrap-${TIMESTAMP}.log"
SSH_SERVICE_NAME=""
STEP_NUM=0

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────

safe_write_log() {
  local level="$1"
  shift || true
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log()  { printf "  ${BLUE}→${NC}  %s\n"   "$*"; safe_write_log INFO  "$*"; }
ok()   { printf "  ${GREEN}✔${NC}  %s\n"  "$*"; safe_write_log OK    "$*"; }
warn() { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; safe_write_log WARN  "$*"; }
err()  { printf "  ${RED}✖${NC}  %s\n"   "$*" >&2; safe_write_log ERROR "$*"; }
die()  { err "$*"; exit 1; }

section() {
  ((STEP_NUM++)) || true
  echo
  printf "${BOLD}${CYAN}  ◈${NC}  ${BOLD}Step ${STEP_NUM}${NC}  ${DIM}─${NC}  ${BOLD}%s${NC}\n" "$1"
  [[ -n "${2:-}" ]] && printf "     ${DIM}%s${NC}\n" "$2"
  echo
}

init_log() {
  mkdir -p /var/log
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  safe_write_log INFO "Bootstrap log started"
}

# ── Spinner ───────────────────────────────────────────────────────────────────

_spinner_pid=""

_spin_loop() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while true; do
    printf "\r  ${CYAN}%s${NC}  %s " "${frames[$((i % 10))]}" "$msg"
    sleep 0.08
    ((i++)) || true
  done
}

spin_start() {
  [[ "$DRY_RUN" -eq 1 || "$VERBOSE" -eq 1 ]] && return 0
  tput civis 2>/dev/null || true
  _spin_loop "$1" &
  _spinner_pid=$!
}

spin_stop() {
  [[ -z "${_spinner_pid:-}" ]] && return 0
  kill "$_spinner_pid" 2>/dev/null || true
  wait "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=""
  tput cnorm 2>/dev/null || true
  printf "\r\033[2K"
}

# ── Core helpers ──────────────────────────────────────────────────────────────

run_cmd() {
  local desc="$1"
  shift
  safe_write_log INFO "RUN: ${desc} :: $*"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${YELLOW}◦${NC}  %s  ${DIM}(dry-run)${NC}\n" "$desc"
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf "  ${CYAN}▶${NC}  %s\n" "$desc"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    return "$rc"
  fi

  spin_start "$desc"
  "$@" >> "$LOG_FILE" 2>&1
  local rc=$?
  spin_stop
  if [[ $rc -eq 0 ]]; then
    printf "  ${GREEN}✔${NC}  %s\n" "$desc"
  else
    printf "  ${RED}✖${NC}  %s\n" "$desc"
  fi
  return $rc
}

cleanup_on_error() {
  local rc=$?
  spin_stop
  tput cnorm 2>/dev/null || true
  if [[ $rc -ne 0 ]]; then
    err "Bootstrap failed. Review log: $LOG_FILE"
  fi
  exit $rc
}

parse_csv_flag() {
  local raw="$1"
  raw="${raw// /}"
  printf '%s' "$raw"
}

should_run_step() {
  local step="$1"
  local item

  if [[ -n "$ONLY_STEPS" ]]; then
    IFS=',' read -r -a only_arr <<< "$ONLY_STEPS"
    for item in "${only_arr[@]}"; do
      [[ "$item" == "$step" ]] && return 0
    done
    return 1
  fi

  if [[ -n "$SKIP_STEPS" ]]; then
    IFS=',' read -r -a skip_arr <<< "$SKIP_STEPS"
    for item in "${skip_arr[@]}"; do
      [[ "$item" == "$step" ]] && return 1
    done
  fi

  return 0
}

write_file() {
  local path="$1"
  local mode="${2:-644}"
  local owner="${3:-root:root}"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${YELLOW}◦${NC}  write %s  ${DIM}(dry-run)${NC}\n" "$path"
    rm -f "$tmp"
    return 0
  fi

  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  safe_write_log INFO "WROTE FILE: $path mode=$mode owner=$owner"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root. Example: sudo bash $0"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply
  while true; do
    if [[ "$default" == "Y" ]]; then
      read -r -p "  ${BOLD}?${NC}  ${prompt} ${DIM}[Y/n]${NC}: " reply
      reply="${reply:-Y}"
    else
      read -r -p "  ${BOLD}?${NC}  ${prompt} ${DIM}[y/N]${NC}: " reply
      reply="${reply:-N}"
    fi
    case "$reply" in
      Y|y|yes|YES) return 0 ;;
      N|n|no|NO)   return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "  ${BOLD}?${NC}  ${prompt} ${DIM}[${default}]${NC}: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "  ${BOLD}?${NC}  ${prompt}: " value
    printf '%s' "$value"
  fi
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp "$f" "${f}.bak.${ts}"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

validate_ssh_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  run_cmd "Install packages: $*" apt-get install -y "$@"
}

apt_install_quiet() {
  export DEBIAN_FRONTEND=noninteractive
  local log_tmp
  log_tmp="$(mktemp /tmp/vps-bootstrap-apt-XXXXXX.log)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${YELLOW}◦${NC}  install packages: %s  ${DIM}(dry-run)${NC}\n" "$*"
    rm -f "$log_tmp"
    return 0
  fi

  spin_start "Installing: $*"
  if apt-get install -y "$@" > "$log_tmp" 2>&1; then
    spin_stop
    printf "  ${GREEN}✔${NC}  Installed: %s\n" "$*"
    cat "$log_tmp" >> "$LOG_FILE"
    rm -f "$log_tmp"
    return 0
  fi

  spin_stop
  cat "$log_tmp" >> "$LOG_FILE"
  err "Package install failed: $*"
  tail -n 20 "$log_tmp" >&2 || true
  rm -f "$log_tmp"
  return 1
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    PRETTY_NAME="${PRETTY_NAME:-$OS_ID}"
  else
    die "Cannot detect OS."
  fi

  case "$OS_ID" in
    ubuntu|debian) ;;
    *) warn "This script was written for Ubuntu/Debian. Detected: ${PRETTY_NAME}" ;;
  esac
}

detect_ssh_service() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    SSH_SERVICE_NAME="ssh"
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    SSH_SERVICE_NAME="sshd"
  else
    SSH_SERVICE_NAME="ssh"
  fi
}

restart_ssh_service() {
  detect_ssh_service
  run_cmd "Restart SSH service" systemctl restart "$SSH_SERVICE_NAME"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --only=*) ONLY_STEPS="$(parse_csv_flag "${1#*=}")" ;;
      --skip=*) SKIP_STEPS="$(parse_csv_flag "${1#*=}")" ;;
      -h|--help)
        cat <<'USAGE'
Usage: sudo bash vps-bootstrap-v1.4.1.sh [options]

Options:
  --dry-run          Show what would happen without making changes
  --verbose          Stream command output to the terminal and log
  --only=a,b,c       Run only selected steps
  --skip=a,b,c       Skip selected steps
  -h, --help         Show this help

Step names:
  user,ssh,sysctl,ufw,fail2ban,git,tailscale,close-ssh,docker,auto-updates,verify
USAGE
        exit 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

# ── Summary ───────────────────────────────────────────────────────────────────

_summary_row() {
  local label="$1"
  local value="$2"
  local icon
  case "${value}" in
    yes)                              icon="${GREEN}✔${NC}" ;;
    skipped|"not created"|"not changed") icon="${DIM}─${NC}" ;;
    "root (no new user created)")     icon="${DIM}─${NC}" ;;
    no|"no ("*)                       icon="${YELLOW}◦${NC}" ;;
    dry-run)                          icon="${YELLOW}◦${NC}" ;;
    *)                                icon="${CYAN}·${NC}" ;;
  esac
  printf "  %b  ${DIM}%-28s${NC}  %s\n" "$icon" "$label" "$value"
}

print_summary() {
  echo
  printf "  ${BOLD}Summary${NC}\n"
  printf "  ${DIM}──────────────────────────────────────────────${NC}\n"

  if [[ "${NEW_USER:-}" == "skipped" ]]; then
    _summary_row "Admin account"          "root (no new user created)"
  else
    _summary_row "Admin user"             "${NEW_USER:-not created}"
  fi
  _summary_row "SSH port"                 "${SSH_PORT_FINAL:-unchanged}"
  _summary_row "Root login disabled"      "${ROOT_LOGIN_CHANGED:-no}"
  _summary_row "Password auth disabled"   "${PASSWORD_AUTH_CHANGED:-no}"
  _summary_row "Kernel hardening"         "${SYSCTL_RESULT:-no}"
  _summary_row "UFW firewall"             "${UFW_ENABLED_RESULT:-no}"
  _summary_row "Allowed public ports"     "${PUBLIC_PORTS_RESULT:-not changed}"
  _summary_row "Fail2ban"                 "${FAIL2BAN_RESULT:-no}"
  _summary_row "Tailscale"                "${TAILSCALE_RESULT:-no}"
  _summary_row "Tailscale SSH"            "${TAILSCALE_SSH_RESULT:-no}"
  _summary_row "Docker"                   "${DOCKER_RESULT:-no}"
  _summary_row "Auto security updates"    "${AUTO_UPDATES_RESULT:-no}"
  _summary_row "GitHub deploy key"        "${GITHUB_KEY_RESULT:-no}"

  printf "  ${DIM}──────────────────────────────────────────────${NC}\n"
  printf "  ${DIM}Log: %s${NC}\n" "$LOG_FILE"
  echo
}

# ── Steps ─────────────────────────────────────────────────────────────────────

create_sudo_user() {
  if ! should_run_step "user"; then
    log "Skipping step: user"
    return 0
  fi

  section "Admin user setup" "Create or configure a non-root admin account with sudo. This is the account you should use for normal server administration instead of logging in as root."

  if ! ask_yes_no "Create or configure a non-root sudo user?" "Y"; then
    NEW_USER="skipped"
    return 0
  fi

  apt_install sudo

  local username
  while true; do
    username="$(ask_input "Enter username for the admin user" "david")"
    [[ -n "$username" ]] || { warn "Username cannot be empty."; continue; }
    [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn "Use a standard Linux username (lowercase, no spaces)."; continue; }
    break
  done

  if id "$username" >/dev/null 2>&1; then
    ok "User '$username' already exists."
  else
    log "Creating user '$username'..."
    warn "You are about to set the password for '${username}'. Linux will ask you to type it twice, and nothing will show while you type."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf "  ${YELLOW}◦${NC}  create user %s  ${DIM}(dry-run)${NC}\n" "$username"
    else
      adduser --gecos "" "$username"
    fi
    ok "User '$username' created."
  fi

  run_cmd "Add ${username} to sudo group" usermod -aG sudo "$username"
  ok "User '$username' added to sudo group."

  run_cmd "Create SSH directory for ${username}" mkdir -p "/home/${username}/.ssh"
  run_cmd "Set SSH directory permissions for ${username}" chmod 700 "/home/${username}/.ssh"
  run_cmd "Set SSH directory ownership for ${username}" chown -R "${username}:${username}" "/home/${username}/.ssh"

  if ask_yes_no "Copy root authorized_keys to '${username}' if present?" "Y"; then
    if [[ -f /root/.ssh/authorized_keys ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "  ${YELLOW}◦${NC}  copy /root/.ssh/authorized_keys to /home/%s/.ssh/authorized_keys  ${DIM}(dry-run)${NC}\n" "$username"
      else
        cp /root/.ssh/authorized_keys "/home/${username}/.ssh/authorized_keys"
        chown "${username}:${username}" "/home/${username}/.ssh/authorized_keys"
        chmod 600 "/home/${username}/.ssh/authorized_keys"
      fi
      ok "Copied SSH keys to '${username}'."
    else
      warn "No /root/.ssh/authorized_keys found."
    fi
  fi

  NEW_USER="$username"
}

configure_ssh() {
  if ! should_run_step "ssh"; then
    log "Skipping step: ssh"
    return 0
  fi

  section "SSH hardening" "Adjust SSH settings carefully. Wrong SSH settings can lock you out, so this script validates the config before restarting SSH."

  backup_file /etc/ssh/sshd_config

  local current_port desired_port
  current_port="$(awk '/^[#[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config || true)"
  current_port="${current_port:-22}"

  if ask_yes_no "Change SSH port from ${current_port}?" "N"; then
    while true; do
      desired_port="$(ask_input "Enter new SSH port" "2293")"
      validate_ssh_port "$desired_port" || { warn "Invalid port."; continue; }
      break
    done
  else
    desired_port="$current_port"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    set_sshd_option "Port" "$desired_port"
  fi
  SSH_PORT_FINAL="$desired_port"

  if [[ "${NEW_USER:-}" == "skipped" || -z "${NEW_USER:-}" ]]; then
    warn "No non-root sudo user was created. Disabling root login could lock you out."
    if ask_yes_no "Disable direct root SSH login?" "N"; then
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "no"
      ROOT_LOGIN_CHANGED="yes"
    else
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "yes"
      ROOT_LOGIN_CHANGED="no"
    fi
  else
    if ask_yes_no "Disable direct root SSH login?" "Y"; then
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "no"
      ROOT_LOGIN_CHANGED="yes"
    else
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "yes"
      ROOT_LOGIN_CHANGED="no"
    fi
  fi

  # Pre-flight: check SSH keys exist before offering to disable password auth
  local check_user="${NEW_USER:-root}"
  [[ "$check_user" == "skipped" ]] && check_user="root"
  local auth_keys_path
  if [[ "$check_user" == "root" ]]; then
    auth_keys_path="/root/.ssh/authorized_keys"
  else
    auth_keys_path="/home/${check_user}/.ssh/authorized_keys"
  fi
  local has_keys=0
  [[ -f "$auth_keys_path" && -s "$auth_keys_path" ]] && has_keys=1

  warn "Disabling SSH password authentication means normal username/password SSH logins will stop working."
  if [[ "$has_keys" -eq 0 ]]; then
    warn "No SSH keys found for '${check_user}' at ${auth_keys_path}."
    warn "Password auth will remain enabled to prevent lockout. Add an SSH key first, then re-run with --only=ssh."
    [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PasswordAuthentication" "yes"
    PASSWORD_AUTH_CHANGED="no (no SSH keys found)"
  elif ask_yes_no "Disable SSH password authentication? Only do this if you have SSH keys or Tailscale SSH working." "N"; then
    [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PasswordAuthentication" "no"
    PASSWORD_AUTH_CHANGED="yes"
  else
    [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PasswordAuthentication" "yes"
    PASSWORD_AUTH_CHANGED="no"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    set_sshd_option "PubkeyAuthentication"            "yes"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication"    "no"
    set_sshd_option "UsePAM"                          "yes"
    set_sshd_option "MaxAuthTries"                    "3"
    set_sshd_option "LoginGraceTime"                  "30"
    set_sshd_option "MaxSessions"                     "3"
    set_sshd_option "X11Forwarding"                   "no"
    set_sshd_option "PermitEmptyPasswords"            "no"
    set_sshd_option "ClientAliveInterval"             "300"
    set_sshd_option "ClientAliveCountMax"             "3"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${YELLOW}◦${NC}  validate and restart SSH service  ${DIM}(dry-run)${NC}\n"
    return 0
  fi

  if sshd -t; then
    restart_ssh_service
    ok "SSH config validated and service restarted."
  else
    die "sshd config test failed. Check /etc/ssh/sshd_config and restore the backup if needed."
  fi
}

configure_sysctl() {
  if ! should_run_step "sysctl"; then
    log "Skipping step: sysctl"
    return 0
  fi

  section "Kernel network hardening" "Apply kernel-level network security parameters. These settings reduce exposure to common network attacks without affecting normal server operation."

  if ! ask_yes_no "Apply kernel network hardening?" "Y"; then
    SYSCTL_RESULT="skipped"
    return 0
  fi

  write_file /etc/sysctl.d/99-vps-bootstrap.conf 644 root:root <<'EOF2'
# VPS Bootstrap — kernel network hardening

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore broadcast ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF2

  run_cmd "Apply kernel parameters" sysctl --system
  SYSCTL_RESULT="yes"
  ok "Kernel network hardening applied."
}

configure_ufw() {
  if ! should_run_step "ufw"; then
    log "Skipping step: ufw"
    return 0
  fi

  section "Firewall setup (UFW)" "Enable a default-deny firewall safely. SSH is allowed first on the active SSH port so the firewall does not cut off your current access."

  if ! ask_yes_no "Enable and configure UFW?" "Y"; then
    UFW_ENABLED_RESULT="skipped"
    return 0
  fi

  apt_install ufw

  local ssh_port="${SSH_PORT_FINAL:-22}"
  log "Allowing SSH first so you do not lock yourself out..."
  run_cmd "Allow SSH port ${ssh_port} through UFW" ufw allow "${ssh_port}/tcp"

  if [[ "$ssh_port" != "22" ]]; then
    if ask_yes_no "Also allow port 22 temporarily during testing?" "N"; then
      run_cmd "Temporarily allow SSH port 22 through UFW" ufw allow 22/tcp
    fi
  fi

  if ask_yes_no "Allow HTTP (80)?" "Y"; then
    run_cmd "Allow HTTP through UFW" ufw allow 80/tcp
  fi

  if ask_yes_no "Allow HTTPS (443)?" "Y"; then
    run_cmd "Allow HTTPS through UFW" ufw allow 443/tcp
  fi

  if ask_yes_no "Apply SSH rate limiting on the active SSH port?" "Y"; then
    run_cmd "Apply SSH rate limiting in UFW" ufw limit "${ssh_port}/tcp"
  fi

  run_cmd "Set UFW default incoming policy to deny" ufw default deny incoming
  run_cmd "Set UFW default outgoing policy to allow" ufw default allow outgoing
  run_cmd "Enable UFW" ufw --force enable

  UFW_ENABLED_RESULT="yes"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    PUBLIC_PORTS_RESULT="dry-run"
  else
    PUBLIC_PORTS_RESULT="$(ufw status numbered | awk '/ALLOW IN|LIMIT IN/ {print $2}' | paste -sd ',' - || true)"
  fi
  ok "UFW is active."
}

install_fail2ban() {
  if ! should_run_step "fail2ban"; then
    log "Skipping step: fail2ban"
    return 0
  fi

  section "Brute-force protection (fail2ban)" "Install fail2ban to watch SSH login failures and temporarily block abusive IP addresses. This helps reduce automated attack noise."

  if ! ask_yes_no "Install fail2ban?" "Y"; then
    FAIL2BAN_RESULT="skipped"
    return 0
  fi

  apt_install_quiet fail2ban
  run_cmd "Create fail2ban jail.d directory" mkdir -p /etc/fail2ban/jail.d

  write_file /etc/fail2ban/jail.d/sshd-local.conf 644 root:root <<EOF2
[DEFAULT]
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT_FINAL:-22}
maxretry = 3
bantime  = 3h
findtime = 10m
EOF2

  run_cmd "Enable fail2ban service" systemctl enable fail2ban
  run_cmd "Restart fail2ban service" systemctl restart fail2ban
  FAIL2BAN_RESULT="yes"
  ok "fail2ban installed and configured for SSH port ${SSH_PORT_FINAL:-22}."
}

install_git_and_github_key() {
  if ! should_run_step "git"; then
    log "Skipping step: git"
    return 0
  fi

  section "Git and GitHub access" "Install git and optionally generate an SSH key for GitHub so the server can clone private repositories over SSH."

  if ! ask_yes_no "Install git?" "Y"; then
    GITHUB_KEY_RESULT="skipped"
    return 0
  fi

  apt_install git openssh-client

  if ! ask_yes_no "Generate a GitHub deploy SSH key for this server?" "Y"; then
    GITHUB_KEY_RESULT="skipped"
    return 0
  fi

  local target_user home_dir key_comment
  if [[ -n "${NEW_USER:-}" && "${NEW_USER}" != "skipped" ]] && id "$NEW_USER" >/dev/null 2>&1; then
    target_user="$NEW_USER"
  else
    target_user="root"
  fi
  home_dir="$(eval echo "~${target_user}")"
  key_comment="$(ask_input "Key comment for GitHub" "${HOSTNAME:-server}")"

  run_cmd "Create .ssh directory for ${target_user}" su - "$target_user" -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'

  if [[ -f "${home_dir}/.ssh/id_ed25519" ]]; then
    warn "SSH key already exists at ${home_dir}/.ssh/id_ed25519"
  else
    run_cmd "Generate GitHub deploy key for ${target_user}" su - "$target_user" -c "ssh-keygen -t ed25519 -C '${key_comment}' -f ~/.ssh/id_ed25519 -N ''"
    ok "Deploy key created for ${target_user}."
  fi

  warn "Adding GitHub to known_hosts using ssh-keyscan. This is convenient, but pinned host keys are stricter."
  run_cmd "Add GitHub to known_hosts for ${target_user}" su - "$target_user" -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 600 ~/.ssh/known_hosts'

  echo
  printf "  ${BOLD}Add this public key to GitHub:${NC}\n\n"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${DIM}[dry-run] Public key would be shown here after generation.${NC}\n"
  else
    cat "${home_dir}/.ssh/id_ed25519.pub"
  fi
  echo
  printf "  ${DIM}GitHub path: Settings → SSH and GPG keys${NC}\n"
  printf "  ${DIM}Repo SSH clone: git@github.com:OWNER/REPO.git${NC}\n"
  GITHUB_KEY_RESULT="yes"
}

install_tailscale() {
  if ! should_run_step "tailscale"; then
    log "Skipping step: tailscale"
    return 0
  fi

  section "Private access with Tailscale" "Install Tailscale so you can reach the server over your Tailnet. Tailscale SSH can later replace public SSH exposure if you want a tighter setup."

  if ! ask_yes_no "Install Tailscale?" "N"; then
    TAILSCALE_RESULT="skipped"
    TAILSCALE_SSH_RESULT="skipped"
    return 0
  fi

  if command_exists tailscale; then
    ok "Tailscale already installed."
  else
    apt_install curl ca-certificates
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf "  ${YELLOW}◦${NC}  install Tailscale  ${DIM}(dry-run)${NC}\n"
    else
      spin_start "Installing Tailscale"
      curl -fsSL https://tailscale.com/install.sh | sh >> "$LOG_FILE" 2>&1
      spin_stop
      printf "  ${GREEN}✔${NC}  Tailscale installed\n"
    fi
  fi

  run_cmd "Enable tailscaled service" systemctl enable tailscaled
  run_cmd "Start tailscaled service" systemctl start tailscaled
  TAILSCALE_RESULT="yes"

  local ts_auth_key
  ts_auth_key="$(ask_input "Optional Tailscale auth key (leave blank for interactive login)" "")"

  if ask_yes_no "Enable Tailscale SSH?" "Y"; then
    if [[ -n "$ts_auth_key" ]]; then
      run_cmd "Bring up Tailscale with SSH enabled" tailscale up --authkey "$ts_auth_key" --ssh
    else
      warn "Interactive Tailscale login may print a URL. Follow it to complete login."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "  ${YELLOW}◦${NC}  tailscale up --ssh  ${DIM}(dry-run)${NC}\n"
      else
        tailscale up --ssh 2>&1 | tee -a "$LOG_FILE" || true
      fi
      warn "If login was not completed, run: sudo tailscale up --ssh"
    fi
    TAILSCALE_SSH_RESULT="yes"
  else
    if [[ -n "$ts_auth_key" ]]; then
      run_cmd "Bring up Tailscale" tailscale up --authkey "$ts_auth_key"
    else
      warn "Interactive Tailscale login may print a URL. Follow it to complete login."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "  ${YELLOW}◦${NC}  tailscale up  ${DIM}(dry-run)${NC}\n"
      else
        tailscale up 2>&1 | tee -a "$LOG_FILE" || true
      fi
      warn "If login was not completed, run: sudo tailscale up"
    fi
    TAILSCALE_SSH_RESULT="no"
  fi
}

offer_close_public_ssh() {
  if ! should_run_step "close-ssh"; then
    log "Skipping step: close-ssh"
    return 0
  fi

  section "Optional public SSH closure" "If Tailscale SSH is working from another terminal, you can remove public SSH firewall access and keep SSH reachable only through Tailscale."

  if ! command_exists ufw; then
    warn "UFW is not installed, so there are no UFW SSH rules to remove."
    return 0
  fi

  if [[ "${TAILSCALE_SSH_RESULT:-no}" != "yes" ]]; then
    log "Skipping close-ssh because Tailscale SSH is not enabled in this run."
    return 0
  fi

  warn "Only close public SSH if you have already confirmed Tailscale SSH works from another terminal."
  warn "Do not do this based on assumption. Test first, then come back and say yes."

  if ask_yes_no "Remove public SSH firewall access and leave SSH reachable only via Tailscale?" "N"; then
    local ssh_port="${SSH_PORT_FINAL:-22}"
    run_cmd "Remove public SSH allow rule for active SSH port" ufw delete allow "${ssh_port}/tcp" || true
    run_cmd "Remove public SSH rate limit rule for active SSH port" ufw delete limit "${ssh_port}/tcp" || true
    run_cmd "Remove public OpenSSH rule" ufw delete allow OpenSSH || true
    run_cmd "Remove public port 22 rule" ufw delete allow 22/tcp || true
    ok "Public SSH rules removed from UFW."
  fi
}

install_docker() {
  if ! should_run_step "docker"; then
    log "Skipping step: docker"
    return 0
  fi

  section "Docker runtime" "Install Docker Engine and Docker Compose so the VPS can run containerized services cleanly."

  if ! ask_yes_no "Install Docker Engine and Docker Compose plugin?" "Y"; then
    DOCKER_RESULT="skipped"
    return 0
  fi

  apt_install ca-certificates curl gnupg
  run_cmd "Create Docker keyring directory" install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf "  ${YELLOW}◦${NC}  fetch Docker GPG key  ${DIM}(dry-run)${NC}\n"
    else
      spin_start "Fetching Docker GPG key"
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      spin_stop
      printf "  ${GREEN}✔${NC}  Docker GPG key fetched\n"
      safe_write_log INFO "Fetched Docker GPG key"
    fi
  fi

  [[ -n "${OS_CODENAME:-}" ]] || die "Could not determine Ubuntu/Debian codename for Docker repo."

  write_file /etc/apt/sources.list.d/docker.list 644 root:root <<EOF2
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable
EOF2

  run_cmd "Update apt package lists after adding Docker repo" apt-get update -y
  run_cmd "Install Docker packages" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd "Enable Docker service" systemctl enable docker
  run_cmd "Start Docker service" systemctl start docker

  if [[ -n "${NEW_USER:-}" && "${NEW_USER}" != "skipped" ]] && id "$NEW_USER" >/dev/null 2>&1; then
    run_cmd "Add ${NEW_USER} to docker group" usermod -aG docker "$NEW_USER"
    ok "Added ${NEW_USER} to docker group."
  fi

  DOCKER_RESULT="yes"
  ok "Docker installed."
}

install_auto_security_updates() {
  if ! should_run_step "auto-updates"; then
    log "Skipping step: auto-updates"
    return 0
  fi

  section "Automatic security updates" "Install unattended-upgrades so the server automatically pulls in security fixes. This reduces the chance of leaving known vulnerabilities unpatched."

  if ! ask_yes_no "Install and configure unattended security upgrades?" "Y"; then
    AUTO_UPDATES_RESULT="skipped"
    return 0
  fi

  apt_install unattended-upgrades apt-listchanges

  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 root:root <<'EOF2'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF2

  write_file /etc/apt/apt.conf.d/52unattended-upgrades-local 644 root:root <<'EOF2'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "";
EOF2

  run_cmd "Enable unattended-upgrades service" systemctl enable unattended-upgrades || true
  run_cmd "Restart unattended-upgrades service" systemctl restart unattended-upgrades || true
  AUTO_UPDATES_RESULT="yes"
  ok "Unattended security upgrades configured."
}

verify_setup() {
  if ! should_run_step "verify"; then
    log "Skipping step: verify"
    return 0
  fi

  section "Verification" "Run a few quick checks so you can confirm the main services and protections are in the expected state."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf "  ${DIM}[dry-run] verification skipped${NC}\n"
    return 0
  fi

  if sshd -t >> "$LOG_FILE" 2>&1; then
    ok "sshd config syntax is valid"
  else
    err "sshd config syntax check failed"
  fi

  if command_exists ufw; then
    local ufw_out
    ufw_out="$(ufw status 2>/dev/null || true)"
    printf "%s\n" "$ufw_out"
    safe_write_log INFO "UFW status: $ufw_out"
  fi

  if command_exists fail2ban-client; then
    if fail2ban-client status >> "$LOG_FILE" 2>&1; then
      ok "fail2ban is responding"
    else
      warn "fail2ban client did not respond cleanly"
    fi
  fi

  if command_exists docker; then
    if systemctl is-active --quiet docker; then
      ok "Docker service is active"
    else
      warn "Docker is installed but service is not active"
    fi
  fi

  if command_exists tailscale; then
    if tailscale status >> "$LOG_FILE" 2>&1; then
      ok "Tailscale status retrieved"
    else
      warn "Tailscale status could not be retrieved cleanly"
    fi
  fi
}

final_notes() {
  local display_user
  if [[ -z "${NEW_USER:-}" || "${NEW_USER}" == "skipped" ]]; then
    display_user="root"
  else
    display_user="$NEW_USER"
  fi

  echo
  printf "  ${BOLD}Next checks${NC}\n"
  printf "  ${DIM}──────────────────────────────────────────────${NC}\n"
  printf "  ${CYAN}1.${NC}  Open a new terminal before closing your current session.\n"
  printf "  ${CYAN}2.${NC}  Test SSH again:\n"
  if [[ "${TAILSCALE_SSH_RESULT:-no}" == "yes" ]]; then
    printf "       ${DIM}tailscale ssh %s@%s${NC}\n" "$display_user" "${HOSTNAME}"
  else
    printf "       ${DIM}ssh %s@SERVER_IP -p %s${NC}\n" "$display_user" "${SSH_PORT_FINAL:-22}"
  fi
  printf "  ${CYAN}3.${NC}  Check firewall:\n"
  printf "       ${DIM}sudo ufw status verbose${NC}\n"
  printf "  ${CYAN}4.${NC}  Check fail2ban:\n"
  printf "       ${DIM}sudo fail2ban-client status${NC}\n"
  printf "  ${CYAN}5.${NC}  Check Docker:\n"
  printf "       ${DIM}docker --version && docker compose version${NC}\n"
  printf "  ${CYAN}6.${NC}  Review the log if needed:\n"
  printf "       ${DIM}sudo less %s${NC}\n" "$LOG_FILE"
  echo
}

main() {
  parse_args "$@"
  require_root
  init_log
  trap cleanup_on_error ERR
  detect_os

  echo
  printf "  ${GREEN}${BOLD}▸  VPS Bootstrap${NC}\n"
  printf "     ${CYAN}v%s${NC}  ${DIM}·  %s${NC}\n" "$SCRIPT_VERSION" "${PRETTY_NAME}"
  printf "  ${BLUE}──────────────────────────────────────────────${NC}\n"
  printf "  ${DIM}Log:  %s${NC}\n" "$LOG_FILE"
  [[ "$DRY_RUN" -eq 1 ]] && printf "  ${YELLOW}Mode: dry-run${NC}\n"
  [[ "$VERBOSE" -eq 1 ]] && printf "  ${CYAN}Mode: verbose${NC}\n"
  echo

  printf "  ${DIM}This script will guide you through the server bootstrap step by step.\n"
  printf "  Some parts are optional. Riskier steps include extra warnings.${NC}\n"
  echo

  if ! ask_yes_no "Continue?" "Y"; then
    exit 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  run_cmd "Update apt package lists" apt-get update -y
  run_cmd "Upgrade installed packages" apt-get upgrade -y

  create_sudo_user
  configure_ssh
  configure_sysctl
  configure_ufw
  install_fail2ban
  install_git_and_github_key
  install_tailscale
  offer_close_public_ssh
  install_docker
  install_auto_security_updates
  verify_setup

  print_summary
  final_notes
  ok "Bootstrap complete."
}

main "$@"
