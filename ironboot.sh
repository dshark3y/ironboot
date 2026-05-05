#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.7.0"
SCRIPT_NAME="$(basename "$0")"

VERBOSE=0
DRY_RUN=0
ASSUME_YES=0
ONLY_STEPS=""
SKIP_STEPS=""
SSH_PORT_OVERRIDE=""
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/ironboot-${TIMESTAMP}.log"
SSH_SERVICE_NAME=""
SSH_CONFIG_TARGET_BACKED_UP=0
LOG_READY=0
STEP_NUM=0

ALL_STEPS=(
  system-update
  user
  ssh
  sysctl
  ufw
  fail2ban
  git
  tailscale
  close-ssh
  docker
  auto-updates
  cron
  verify
)

# ── Colors (disabled when not running in a TTY) ───────────────────────────────

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────

print_line() {
  printf '%b\n' "$1"
}

print_raw() {
  printf '%b' "$1"
}

safe_write_log() {
  local level="$1"
  shift || true
  if [[ "$LOG_READY" -eq 1 && -n "${LOG_FILE:-}" ]]; then
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log()  { print_line "  ${BLUE}→${NC}  $*"; safe_write_log INFO  "$*"; }
ok()   { print_line "  ${GREEN}✔${NC}  $*"; safe_write_log OK    "$*"; }
warn() { print_line "  ${YELLOW}⚠${NC}  $*"; safe_write_log WARN  "$*"; }
err()  { print_line "  ${RED}✖${NC}  $*" >&2; safe_write_log ERROR "$*"; }
die()  { err "$*"; exit 1; }

section() {
  ((STEP_NUM++)) || true
  echo
  print_line "${BOLD}${CYAN}  ◈${NC}  ${BOLD}Step ${STEP_NUM}${NC}  ${DIM}─${NC}  ${BOLD}${1}${NC}"
  [[ -n "${2:-}" ]] && print_line "     ${DIM}${2}${NC}"
  echo
}

init_log() {
  mkdir -p /var/log
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  LOG_READY=1
  safe_write_log INFO "ironboot log started"
}

# ── Spinner ───────────────────────────────────────────────────────────────────

_spinner_pid=""

_spin_loop() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while true; do
    print_raw "\r  ${CYAN}${frames[$((i % 10))]}${NC}  ${msg} "
    sleep 0.08
    ((i++)) || true
  done
}

spin_start() {
  [[ "$DRY_RUN" -eq 1 || "$VERBOSE" -eq 1 || ! -t 1 ]] && return 0
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
    print_line "  ${YELLOW}◦${NC}  ${desc}  ${DIM}(dry-run)${NC}"
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    print_line "  ${CYAN}▶${NC}  ${desc}"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    return "$rc"
  fi

  spin_start "$desc"
  "$@" >> "$LOG_FILE" 2>&1
  local rc=$?
  spin_stop
  if [[ $rc -eq 0 ]]; then
    print_line "  ${GREEN}✔${NC}  ${desc}"
  else
    print_line "  ${RED}✖${NC}  ${desc}"
  fi
  return $rc
}

cleanup_on_error() {
  local rc=$?
  spin_stop
  tput cnorm 2>/dev/null || true
  if [[ $rc -ne 0 ]]; then
    err "ironboot failed. Review log: $LOG_FILE"
  fi
  exit $rc
}

parse_csv_flag() {
  local raw="$1"
  raw="${raw// /}"
  printf '%s' "$raw"
}

step_names_csv() {
  local IFS=,
  printf '%s' "${ALL_STEPS[*]}"
}

is_valid_step() {
  local step="$1"
  local item
  for item in "${ALL_STEPS[@]}"; do
    [[ "$item" == "$step" ]] && return 0
  done
  return 1
}

validate_step_list() {
  local flag_name="$1"
  local raw="$2"
  local item
  local -a step_arr

  [[ -n "$raw" ]] || die "${flag_name} requires at least one step. Valid steps: $(step_names_csv)"

  IFS=',' read -r -a step_arr <<< "$raw"
  for item in "${step_arr[@]}"; do
    [[ -n "$item" ]] || die "${flag_name} contains an empty step. Valid steps: $(step_names_csv)"
    is_valid_step "$item" || die "Unknown step '${item}' in ${flag_name}. Valid steps: $(step_names_csv)"
  done
}

should_run_step() {
  local step="$1"
  local item
  local -a only_arr skip_arr

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
    print_line "  ${YELLOW}◦${NC}  write ${path}  ${DIM}(dry-run)${NC}"
    rm -f "$tmp"
    return 0
  fi

  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  safe_write_log INFO "WROTE FILE: $path mode=$mode owner=$owner"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root. Example: sudo bash ${SCRIPT_NAME}"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local hint="${3:-}"
  local reply
  [[ -n "$hint" ]] && print_line "  ${DIM}↳ ${hint}${NC}"

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    if [[ "$default" == "Y" ]]; then
      print_line "  ${BOLD}?${NC}  ${prompt} ${DIM}[Y/n]${NC}: Y ${DIM}(--yes)${NC}"
      return 0
    fi
    print_line "  ${BOLD}?${NC}  ${prompt} ${DIM}[y/N]${NC}: N ${DIM}(--yes default)${NC}"
    return 1
  fi

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

sshd_dropin_supported() {
  [[ -d /etc/ssh/sshd_config.d ]] || return 1
  [[ -f /etc/ssh/sshd_config ]] || return 1
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config
}

managed_sshd_config_file() {
  if sshd_dropin_supported; then
    printf '%s\n' "/etc/ssh/sshd_config.d/99-ironboot.conf"
  else
    printf '%s\n' "/etc/ssh/sshd_config"
  fi
}

ensure_sshd_dropin_header() {
  local file="$1"
  [[ "$file" == "/etc/ssh/sshd_config.d/99-ironboot.conf" ]] || return 0
  [[ -f "$file" ]] && return 0

  {
    printf '# Managed by ironboot. Local edits may be overwritten by reruns.\n'
    printf '# SSH hardening and port settings.\n'
  } > "$file"
  chmod 644 "$file"
  safe_write_log INFO "WROTE FILE: $file mode=644 owner=root:root"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file
  file="$(managed_sshd_config_file)"

  if [[ "$SSH_CONFIG_TARGET_BACKED_UP" -eq 0 ]]; then
    backup_file "$file"
    SSH_CONFIG_TARGET_BACKED_UP=1
  fi

  ensure_sshd_dropin_header "$file"

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
  log_tmp="$(mktemp /tmp/ironboot-apt-XXXXXX.log)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_line "  ${YELLOW}◦${NC}  install packages: $*  ${DIM}(dry-run)${NC}"
    rm -f "$log_tmp"
    return 0
  fi

  spin_start "Installing: $*"
  if apt-get install -y "$@" > "$log_tmp" 2>&1; then
    spin_stop
    print_line "  ${GREEN}✔${NC}  Installed: $*"
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

detect_current_ssh_port() {
  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    printf '%s' "$SSH_PORT_OVERRIDE"
    return 0
  fi

  local port=""
  if [[ -f /etc/ssh/sshd_config.d/99-ironboot.conf ]]; then
    port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config.d/99-ironboot.conf 2>/dev/null || true)"
    if [[ -n "$port" ]]; then
      printf '%s' "$port"
      return 0
    fi
  fi

  local config_files=()
  [[ -f /etc/ssh/sshd_config ]] && config_files+=("/etc/ssh/sshd_config")

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    local dropin
    shopt -s nullglob
    for dropin in /etc/ssh/sshd_config.d/*.conf; do
      config_files+=("$dropin")
    done
    shopt -u nullglob
  fi

  if [[ "${#config_files[@]}" -gt 0 ]]; then
    port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "${config_files[@]}" 2>/dev/null || true)"
  fi

  printf '%s' "${port:-22}"
}

current_ssh_port() {
  printf '%s' "${SSH_PORT_FINAL:-$(detect_current_ssh_port)}"
}

tailscale_is_available() {
  command_exists tailscale && tailscale status >/dev/null 2>&1
}

print_help() {
  cat <<USAGE
Usage: sudo bash ${SCRIPT_NAME} [options]

Options:
  --dry-run          Show what would happen without making changes
  --verbose          Stream command output to the terminal and log
  --yes              Accept prompt defaults without interactive confirmation
  --ssh-port=PORT    Override detected SSH port for firewall/fail2ban reruns
  --only=a,b,c       Run only selected steps
  --skip=a,b,c       Skip selected steps
  --version          Print version and exit
  -h, --help         Show this help

Step names:
  $(step_names_csv)
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --yes) ASSUME_YES=1 ;;
      --ssh-port=*)
        SSH_PORT_OVERRIDE="${1#*=}"
        validate_ssh_port "$SSH_PORT_OVERRIDE" || die "Invalid --ssh-port value: ${SSH_PORT_OVERRIDE}"
        ;;
      --only=*) ONLY_STEPS="$(parse_csv_flag "${1#*=}")" ;;
      --skip=*) SKIP_STEPS="$(parse_csv_flag "${1#*=}")" ;;
      --version)
        printf '%s\n' "$SCRIPT_VERSION"
        exit 0
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done

  [[ -n "$ONLY_STEPS" ]] && validate_step_list "--only" "$ONLY_STEPS"
  [[ -n "$SKIP_STEPS" ]] && validate_step_list "--skip" "$SKIP_STEPS"
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
  printf '  %b  %b%-28s%b  %s\n' "$icon" "$DIM" "$label" "$NC" "$value"
}

print_summary() {
  local ssh_summary_port
  ssh_summary_port="$(current_ssh_port)"

  echo
  print_line "  ${BOLD}Summary${NC}"
  print_line "  ${DIM}──────────────────────────────────────────────${NC}"

  _summary_row "System update"            "${SYSTEM_UPDATE_RESULT:-no}"
  if [[ "${NEW_USER:-}" == "skipped" ]]; then
    _summary_row "Admin account"          "root (no new user created)"
  else
    _summary_row "Admin user"             "${NEW_USER:-not created}"
  fi
  _summary_row "SSH port"                 "$ssh_summary_port"
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
  _summary_row "Scheduled maintenance"    "${CRON_RESULT:-no}"
  _summary_row "GitHub deploy key"        "${GITHUB_KEY_RESULT:-no}"

  print_line "  ${DIM}──────────────────────────────────────────────${NC}"
  print_line "  ${DIM}Log: ${LOG_FILE}${NC}"
  echo
}

# ── Steps ─────────────────────────────────────────────────────────────────────

run_system_update() {
  if ! should_run_step "system-update"; then
    log "Skipping step: system-update"
    return 0
  fi

  section "System package update" "Refresh apt package lists and upgrade installed packages. This runs during full bootstrap, but not during narrow --only reruns unless explicitly selected."

  if ! ask_yes_no "Update apt package lists and upgrade installed packages?" "Y" "Recommended on a fresh VPS. For existing production servers, run this deliberately rather than as a side effect of another step."; then
    SYSTEM_UPDATE_RESULT="skipped"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  run_cmd "Update apt package lists" apt-get update -y
  run_cmd "Upgrade installed packages" apt-get upgrade -y
  SYSTEM_UPDATE_RESULT="yes"
}

create_sudo_user() {
  if ! should_run_step "user"; then
    log "Skipping step: user"
    return 0
  fi

  section "Admin user setup" "Create or configure a non-root admin account with sudo. This is the account you should use for normal server administration instead of logging in as root."

  if ! ask_yes_no "Create or configure a non-root sudo user?" "Y" "Recommended — running everything as root means one mistake has full system consequences."; then
    NEW_USER="skipped"
    return 0
  fi

  apt_install sudo

  local username
  while true; do
    username="$(ask_input "Enter username for the admin user" "your-name")"
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
      print_line "  ${YELLOW}◦${NC}  create user ${username}  ${DIM}(dry-run)${NC}"
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

  if ask_yes_no "Copy root authorized_keys to '${username}' if present?" "Y" "Recommended — copies your existing SSH key so you can log in as the new user without re-adding it."; then
    if [[ -f /root/.ssh/authorized_keys ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        print_line "  ${YELLOW}◦${NC}  copy /root/.ssh/authorized_keys to /home/${username}/.ssh/authorized_keys  ${DIM}(dry-run)${NC}"
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
  current_port="$(detect_current_ssh_port)"

  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    desired_port="$SSH_PORT_OVERRIDE"
    log "Using SSH port from --ssh-port=${SSH_PORT_OVERRIDE}."
  elif ask_yes_no "Change SSH port from ${current_port}?" "N" "Optional — reduces automated scan noise. Common alternatives: 2222, 2293. Skip if port 22 is fine."; then
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
    if ask_yes_no "Disable direct root SSH login?" "N" "Risky without a non-root user. Only say yes if you have another way in (e.g. console access)."; then
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "no"
      ROOT_LOGIN_CHANGED="yes"
    else
      [[ "$DRY_RUN" -eq 0 ]] && set_sshd_option "PermitRootLogin" "yes"
      ROOT_LOGIN_CHANGED="no"
    fi
  else
    if ask_yes_no "Disable direct root SSH login?" "Y" "Recommended — your admin user handles everything; root should not be directly reachable over SSH."; then
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
  elif ask_yes_no "Disable SSH password authentication? Only do this if you have SSH keys or Tailscale SSH working." "N" "Recommended only if you have confirmed key-based SSH access. Locks out all password logins permanently."; then
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
    print_line "  ${YELLOW}◦${NC}  validate and restart SSH service  ${DIM}(dry-run)${NC}"
    return 0
  fi

  # Ensure SSH privilege separation directory exists before validation.
  # On Ubuntu 24.04 with socket-activated SSH, /run/sshd may not exist
  # until a connection is made — sshd -t fails without it.
  mkdir -p /run/sshd
  chmod 0755 /run/sshd

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

  if ! ask_yes_no "Apply kernel network hardening?" "Y" "Recommended — low-risk settings, no impact on normal operation. Prevents SYN floods, ICMP redirects, and source routing."; then
    SYSCTL_RESULT="skipped"
    return 0
  fi

  write_file /etc/sysctl.d/99-ironboot.conf 644 root:root <<'EOF2'
# Managed by ironboot. Local edits may be overwritten by reruns.
# ironboot kernel network hardening

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

  if ! ask_yes_no "Enable and configure UFW?" "Y" "Recommended — a default-deny firewall is one of the most effective baseline protections for any VPS."; then
    UFW_ENABLED_RESULT="skipped"
    return 0
  fi

  apt_install ufw

  local ssh_port
  ssh_port="$(current_ssh_port)"
  log "Allowing SSH first so you do not lock yourself out..."
  run_cmd "Allow SSH port ${ssh_port} through UFW" ufw allow "${ssh_port}/tcp"

  if [[ "$ssh_port" != "22" ]]; then
    if ask_yes_no "Also allow port 22 temporarily during testing?" "N" "Optional — useful as a fallback if the new port doesn't work. Remove it once you've confirmed the new port."; then
      run_cmd "Temporarily allow SSH port 22 through UFW" ufw allow 22/tcp
    fi
  fi

  if ask_yes_no "Allow HTTP (80)?" "Y" "Yes if this server will serve websites or run a reverse proxy (Nginx, Traefik, Caddy)."; then
    run_cmd "Allow HTTP through UFW" ufw allow 80/tcp
  fi

  if ask_yes_no "Allow HTTPS (443)?" "Y" "Yes if this server will serve SSL/TLS traffic. Almost always yes if HTTP is also allowed."; then
    run_cmd "Allow HTTPS through UFW" ufw allow 443/tcp
  fi

  if ask_yes_no "Apply SSH rate limiting on the active SSH port?" "Y" "Recommended — limits login attempts per IP, works alongside fail2ban to slow brute-force attacks."; then
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

  if ! ask_yes_no "Install fail2ban?" "Y" "Recommended — automatically bans IPs with repeated failed SSH login attempts."; then
    FAIL2BAN_RESULT="skipped"
    return 0
  fi

  apt_install_quiet fail2ban
  run_cmd "Create fail2ban jail.d directory" mkdir -p /etc/fail2ban/jail.d

  local ssh_port
  ssh_port="$(current_ssh_port)"

  write_file /etc/fail2ban/jail.d/sshd-local.conf 644 root:root <<EOF2
# Managed by ironboot. Local edits may be overwritten by reruns.
[DEFAULT]
banaction = ufw

[sshd]
enabled  = true
port     = ${ssh_port}
maxretry = 3
bantime  = 3h
findtime = 10m
EOF2

  run_cmd "Enable fail2ban service" systemctl enable fail2ban
  run_cmd "Restart fail2ban service" systemctl restart fail2ban
  FAIL2BAN_RESULT="yes"
  ok "fail2ban installed and configured for SSH port ${ssh_port}."
}

install_git_and_github_key() {
  if ! should_run_step "git"; then
    log "Skipping step: git"
    return 0
  fi

  section "Git and GitHub access" "Install git and optionally generate an SSH key for GitHub so the server can clone private repositories over SSH."

  if ! ask_yes_no "Install git?" "Y" "Recommended — you will almost certainly need git to manage code on this server."; then
    GITHUB_KEY_RESULT="skipped"
    return 0
  fi

  apt_install git openssh-client

  if ! ask_yes_no "Generate a GitHub deploy SSH key for this server?" "Y" "Recommended if this server needs to pull from private GitHub repos."; then
    GITHUB_KEY_RESULT="skipped"
    return 0
  fi

  local target_user home_dir key_comment
  if [[ -n "${NEW_USER:-}" && "${NEW_USER}" != "skipped" ]] && id "$NEW_USER" >/dev/null 2>&1; then
    target_user="$NEW_USER"
  else
    target_user="root"
  fi
  home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || die "Could not determine home directory for ${target_user}."
  key_comment="$(ask_input "Key comment for GitHub" "${HOSTNAME:-server}")"

  run_cmd "Create .ssh directory for ${target_user}" mkdir -p "${home_dir}/.ssh"
  run_cmd "Set .ssh permissions for ${target_user}" chmod 700 "${home_dir}/.ssh"
  run_cmd "Set .ssh ownership for ${target_user}" chown -R "${target_user}:${target_user}" "${home_dir}/.ssh"

  if [[ -f "${home_dir}/.ssh/id_ed25519" ]]; then
    warn "SSH key already exists at ${home_dir}/.ssh/id_ed25519"
  else
    run_cmd "Generate GitHub deploy key for ${target_user}" ssh-keygen -t ed25519 -C "$key_comment" -f "${home_dir}/.ssh/id_ed25519" -N ""
    run_cmd "Set deploy key ownership for ${target_user}" chown "${target_user}:${target_user}" "${home_dir}/.ssh/id_ed25519" "${home_dir}/.ssh/id_ed25519.pub"
    ok "Deploy key created for ${target_user}."
  fi

  warn "Adding GitHub to known_hosts using ssh-keyscan. This is convenient, but pinned host keys are stricter."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_line "  ${YELLOW}◦${NC}  add GitHub to known_hosts for ${target_user}  ${DIM}(dry-run)${NC}"
  else
    if ssh-keyscan github.com >> "${home_dir}/.ssh/known_hosts" 2>> "$LOG_FILE"; then
      chown "${target_user}:${target_user}" "${home_dir}/.ssh/known_hosts"
      chmod 600 "${home_dir}/.ssh/known_hosts"
      ok "Added GitHub to known_hosts for ${target_user}."
    else
      die "Could not add GitHub to known_hosts. Review log: $LOG_FILE"
    fi
  fi

  echo
  print_line "  ${BOLD}Add this public key to GitHub:${NC}"
  echo
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_line "  ${DIM}[dry-run] Public key would be shown here after generation.${NC}"
  else
    cat "${home_dir}/.ssh/id_ed25519.pub"
  fi
  echo
  print_line "  ${DIM}Add it here: https://github.com/settings/ssh/new${NC}"
  print_line "  ${DIM}Or navigate: GitHub → Settings → SSH and GPG keys → New SSH key${NC}"
  print_line "  ${DIM}Repo SSH clone: git@github.com:OWNER/REPO.git${NC}"
  GITHUB_KEY_RESULT="yes"
}

install_tailscale() {
  if ! should_run_step "tailscale"; then
    log "Skipping step: tailscale"
    return 0
  fi

  section "Private access with Tailscale" "Install Tailscale so you can reach the server over your Tailnet. Tailscale SSH can later replace public SSH exposure if you want a tighter setup."

  if ! ask_yes_no "Install Tailscale?" "N" "Recommended — adds the server to your private Tailnet, eliminating the need to expose SSH publicly."; then
    TAILSCALE_RESULT="skipped"
    TAILSCALE_SSH_RESULT="skipped"
    return 0
  fi

  if command_exists tailscale; then
    ok "Tailscale already installed."
  else
    apt_install curl ca-certificates
    if [[ "$DRY_RUN" -eq 1 ]]; then
      print_line "  ${YELLOW}◦${NC}  install Tailscale  ${DIM}(dry-run)${NC}"
    else
      spin_start "Installing Tailscale"
      if curl -fsSL https://tailscale.com/install.sh | sh >> "$LOG_FILE" 2>&1; then
        spin_stop
        print_line "  ${GREEN}✔${NC}  Tailscale installed"
      else
        spin_stop
        die "Tailscale install failed. Review log: $LOG_FILE"
      fi
    fi
  fi

  run_cmd "Enable tailscaled service" systemctl enable tailscaled
  run_cmd "Start tailscaled service" systemctl start tailscaled
  TAILSCALE_RESULT="yes"

  local ts_auth_key
  ts_auth_key="$(ask_input "Optional Tailscale auth key (leave blank for interactive login)" "")"

  if ask_yes_no "Enable Tailscale SSH?" "Y" "Recommended — lets you SSH over Tailscale so you can later close public SSH access entirely."; then
    if [[ -n "$ts_auth_key" ]]; then
      run_cmd "Bring up Tailscale with SSH enabled" tailscale up --authkey "$ts_auth_key" --ssh
    else
      warn "Interactive Tailscale login may print a URL. Follow it to complete login."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        print_line "  ${YELLOW}◦${NC}  tailscale up --ssh  ${DIM}(dry-run)${NC}"
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
        print_line "  ${YELLOW}◦${NC}  tailscale up  ${DIM}(dry-run)${NC}"
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

  if [[ "${TAILSCALE_SSH_RESULT:-no}" != "yes" ]] && ! tailscale_is_available; then
    log "Skipping close-ssh because Tailscale is not connected."
    return 0
  fi

  if [[ "${TAILSCALE_SSH_RESULT:-no}" != "yes" ]]; then
    warn "Tailscale appears connected, but this run did not enable Tailscale SSH."
  fi

  warn "Only close public SSH if you have already confirmed Tailscale SSH works from another terminal."
  warn "Do not do this based on assumption. Test first, then come back and say yes."

  if ask_yes_no "Remove public SSH firewall access and leave SSH reachable only via Tailscale?" "N" "Only say yes if you have already confirmed Tailscale SSH works from another terminal right now."; then
    local ssh_port
    ssh_port="$(current_ssh_port)"
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

  if ! ask_yes_no "Install Docker Engine and Docker Compose plugin?" "Y" "Yes if you plan to run containerised services. Installs the official Docker Engine, not the distro package."; then
    DOCKER_RESULT="skipped"
    return 0
  fi

  apt_install ca-certificates curl gnupg
  run_cmd "Create Docker keyring directory" install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      print_line "  ${YELLOW}◦${NC}  fetch Docker GPG key  ${DIM}(dry-run)${NC}"
    else
      spin_start "Fetching Docker GPG key"
      if curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        chmod a+r /etc/apt/keyrings/docker.gpg
        spin_stop
        print_line "  ${GREEN}✔${NC}  Docker GPG key fetched"
        safe_write_log INFO "Fetched Docker GPG key"
      else
        spin_stop
        die "Docker GPG key fetch failed. Review log: $LOG_FILE"
      fi
    fi
  fi

  [[ -n "${OS_CODENAME:-}" ]] || die "Could not determine Ubuntu/Debian codename for Docker repo."

  write_file /etc/apt/sources.list.d/docker.list 644 root:root <<EOF2
# Managed by ironboot. Local edits may be overwritten by reruns.
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

  if ! ask_yes_no "Install and configure unattended security upgrades?" "Y" "Recommended — applies security patches automatically so known CVEs don't sit unpatched."; then
    AUTO_UPDATES_RESULT="skipped"
    return 0
  fi

  apt_install unattended-upgrades apt-listchanges

  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 root:root <<'EOF2'
// Managed by ironboot. Local edits may be overwritten by reruns.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF2

  write_file /etc/apt/apt.conf.d/52unattended-upgrades-local 644 root:root <<'EOF2'
// Managed by ironboot. Local edits may be overwritten by reruns.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "";
EOF2

  run_cmd "Enable unattended-upgrades service" systemctl enable unattended-upgrades || true
  run_cmd "Restart unattended-upgrades service" systemctl restart unattended-upgrades || true
  AUTO_UPDATES_RESULT="yes"
  ok "Unattended security upgrades configured."
}

install_cron_jobs() {
  if ! should_run_step "cron"; then
    log "Skipping step: cron"
    return 0
  fi

  section "Scheduled maintenance" "Optionally schedule weekly jobs to keep the server automatically updated — full system upgrades, Docker image pulls, and disk cleanup."

  local want_apt=0 want_docker=0

  if ask_yes_no "Run a weekly full apt upgrade?" "Y" "Recommended — unattended-upgrades only applies security patches; this catches everything else and runs autoremove."; then
    want_apt=1
  fi

  if command_exists docker; then
    if ask_yes_no "Run weekly Docker image updates and prune?" "Y" "Recommended — pulls latest images for all running containers and removes dangling images. Works automatically once containers are deployed."; then
      want_docker=1
    fi
  else
    log "Docker not installed — skipping Docker maintenance options."
  fi

  if [[ "$want_apt" -eq 0 && "$want_docker" -eq 0 ]]; then
    CRON_RESULT="skipped"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_line "  ${YELLOW}◦${NC}  write /usr/local/bin/vps-maintenance  ${DIM}(dry-run)${NC}"
    print_line "  ${YELLOW}◦${NC}  write /etc/cron.d/vps-maintenance  ${DIM}(dry-run)${NC}"
    CRON_RESULT="dry-run"
    return 0
  fi

  local maint_tmp
  maint_tmp="$(mktemp)"

  {
    printf '#!/usr/bin/env bash\n'
    printf '# Managed by ironboot. Local edits may be overwritten by reruns.\n'
    printf '# ironboot vps-maintenance — generated %s\n' "$(date)"
    printf '# Edit this file to change what runs on the weekly maintenance schedule.\n'
    printf 'set -euo pipefail\n'
    printf '\n'
    printf 'LOG=/var/log/vps-maintenance.log\n'
    printf 'exec >> "%s" 2>&1\n' "\${LOG}"
    printf 'echo ""\n'
    printf 'echo "=== vps-maintenance started %s ==="\n' "\$(date)"
    printf '\n'

    if [[ "$want_apt" -eq 1 ]]; then
      printf '# ── Full system upgrade ──────────────────────────────────────────────────────\n'
      printf 'echo "--- apt upgrade ---"\n'
      printf 'apt-get update -y\n'
      printf 'apt-get upgrade -y\n'
      printf 'apt-get autoremove -y\n'
      printf '\n'
    fi

    if [[ "$want_docker" -eq 1 ]]; then
      printf '# ── Docker image updates ─────────────────────────────────────────────────────\n'
      printf 'echo "--- docker image pull ---"\n'
      printf 'docker ps --format "{{.Image}}" | sort -u | while read -r img; do\n'
      printf '  docker pull "%s" || echo "pull failed: %s"\n' "\${img}" "\${img}"
      printf 'done\n'
      printf '\n'
      printf '# ── Docker cleanup ───────────────────────────────────────────────────────────\n'
      printf 'echo "--- docker prune ---"\n'
      printf 'docker image prune -f\n'
      printf 'docker container prune -f\n'
      printf '\n'
      printf '# ── Compose restart (optional) ───────────────────────────────────────────────\n'
      printf '# Uncomment and set COMPOSE_DIR to auto-restart a stack after image pulls.\n'
      printf '# Example: COMPOSE_DIR=/opt/myapp\n'
      printf '#\n'
      printf '# COMPOSE_DIR=\n'
      printf '# if [[ -d "%s" ]]; then\n' "\${COMPOSE_DIR}"
      printf '#   echo "--- docker compose up in %s ---"\n' "\${COMPOSE_DIR}"
      printf '#   (cd "%s" && docker compose pull && docker compose up -d)\n' "\${COMPOSE_DIR}"
      printf '# fi\n'
      printf '\n'
    fi

    printf 'echo "=== vps-maintenance complete %s ==="\n' "\$(date)"
  } > "$maint_tmp"

  install -o root -g root -m 755 "$maint_tmp" /usr/local/bin/vps-maintenance
  rm -f "$maint_tmp"
  safe_write_log INFO "WROTE FILE: /usr/local/bin/vps-maintenance"

  write_file /etc/cron.d/vps-maintenance 644 root:root <<'CRONEOF'
# Managed by ironboot. Local edits may be overwritten by reruns.
# ironboot vps-maintenance — weekly Sunday 03:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0   root   /usr/local/bin/vps-maintenance
CRONEOF

  local summary_str=""
  [[ "$want_apt"    -eq 1 ]] && summary_str+="${summary_str:+, }apt upgrade"
  [[ "$want_docker" -eq 1 ]] && summary_str+="${summary_str:+, }docker pull+prune"

  CRON_RESULT="yes"
  ok "Maintenance cron scheduled (Sunday 03:00): ${summary_str}."
  log "Script: /usr/local/bin/vps-maintenance  |  Cron: /etc/cron.d/vps-maintenance"
}

verify_setup() {
  if ! should_run_step "verify"; then
    log "Skipping step: verify"
    return 0
  fi

  section "Verification" "Run a few quick checks so you can confirm the main services and protections are in the expected state."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_line "  ${DIM}[dry-run] verification skipped${NC}"
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
  # Pick the most accurate login example based on what's actually available.
  # If a non-root user was created/configured this run, use them.
  # Otherwise, only suggest root if root login is still allowed.
  local display_user=""
  local ssh_port
  ssh_port="$(current_ssh_port)"
  if [[ -n "${NEW_USER:-}" && "${NEW_USER}" != "skipped" ]]; then
    display_user="$NEW_USER"
  elif [[ "${ROOT_LOGIN_CHANGED:-no}" != "yes" ]]; then
    display_user="root"
  fi

  echo
  print_line "  ${BOLD}Next checks${NC}"
  print_line "  ${DIM}──────────────────────────────────────────────${NC}"
  print_line "  ${CYAN}1.${NC}  Open a new terminal before closing your current session."
  print_line "  ${CYAN}2.${NC}  Test SSH again:"
  if [[ -z "$display_user" ]]; then
    print_line "       ${YELLOW}Root login is disabled and no admin user was set up in this run.${NC}"
    print_line "       ${DIM}Use an existing admin account: ssh YOUR_USER@SERVER_IP -p ${ssh_port}${NC}"
    print_line "       ${DIM}If locked out, restore /etc/ssh/sshd_config.bak.* and restart SSH.${NC}"
  elif [[ "${TAILSCALE_SSH_RESULT:-no}" == "yes" ]]; then
    print_line "       ${DIM}tailscale ssh ${display_user}@${HOSTNAME}${NC}"
  else
    print_line "       ${DIM}ssh ${display_user}@SERVER_IP -p ${ssh_port}${NC}"
  fi
  print_line "  ${CYAN}3.${NC}  Check firewall:"
  print_line "       ${DIM}sudo ufw status verbose${NC}"
  print_line "  ${CYAN}4.${NC}  Check fail2ban:"
  print_line "       ${DIM}sudo fail2ban-client status${NC}"
  print_line "  ${CYAN}5.${NC}  Check Docker:"
  print_line "       ${DIM}docker --version && docker compose version${NC}"
  if [[ "${CRON_RESULT:-no}" == "yes" ]]; then
    print_line "  ${CYAN}6.${NC}  Review or edit the maintenance script:"
    print_line "       ${DIM}sudo cat /usr/local/bin/vps-maintenance${NC}"
    print_line "       ${DIM}sudo cat /etc/cron.d/vps-maintenance${NC}"
    print_line "  ${CYAN}7.${NC}  Review the log if needed:"
  else
    print_line "  ${CYAN}6.${NC}  Review the log if needed:"
  fi
  print_line "       ${DIM}sudo less ${LOG_FILE}${NC}"
  echo
}

main() {
  parse_args "$@"
  require_root
  init_log
  trap cleanup_on_error ERR
  detect_os

  echo
  print_line "  ${GREEN}${BOLD}▸  ironboot${NC}"
  print_line "     ${CYAN}v${SCRIPT_VERSION}${NC}  ${DIM}·  ${PRETTY_NAME}${NC}"
  print_line "  ${BLUE}──────────────────────────────────────────────${NC}"
  print_line "  ${DIM}Log:  ${LOG_FILE}${NC}"
  [[ "$DRY_RUN" -eq 1 ]] && print_line "  ${YELLOW}Mode: dry-run${NC}"
  [[ "$VERBOSE" -eq 1 ]] && print_line "  ${CYAN}Mode: verbose${NC}"
  echo

  print_line "  ${DIM}This script will guide you through the server bootstrap step by step."
  print_line "  Some parts are optional. Riskier steps include extra warnings.${NC}"
  echo

  if ! ask_yes_no "Continue?" "Y"; then
    exit 0
  fi

  export DEBIAN_FRONTEND=noninteractive

  run_system_update
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
  install_cron_jobs
  verify_setup

  print_summary
  final_notes
  ok "ironboot complete."
}

main "$@"
