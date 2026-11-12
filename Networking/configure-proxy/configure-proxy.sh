#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: configure-proxy.sh [TARGETS] --http_proxy URL --https_proxy URL
                          --no_proxy LIST [--apply] [--restartdaemons]
       configure-proxy.sh [TARGETS] --remove [--apply] [--restartdaemons]

Targets, selected independently:
  --environment          Set all six proxy variables in /etc/environment.
  --profile              Write /etc/profile.d/90-explicit-proxy.sh.
  --sudoers              Write /etc/sudoers.d/90-explicit-proxy.
  --waagent              Write a waagent.service drop-in if the unit is
                         available; otherwise warn and skip this target.
  --daemons LIST        Write drop-ins for comma-separated .service unit names.
                         May be repeated. Unavailable units warn and skip.
  --alldefaults          Select environment, profile, sudoers and optional waagent.

Values:
  --http_proxy URL       HTTP proxy URL: http(s)://host[:port].
  --https_proxy URL      HTTPS proxy URL: http(s)://host[:port].
  --no_proxy LIST        Comma-separated hosts, IPs, suffixes or CIDRs; may be
                         empty. An optional port is allowed for hosts/IPs.
                         Use [IPv6]:port when specifying an IPv6 port.
  --dropin-name NAME     Basename for managed files (default: 90-explicit-proxy).
                         Start with a letter or digit; use letters, digits,
                         underscores or hyphens. Maximum 250 characters.
                         Supply no extension or directory.

  --apply                Apply configuration or removal. Otherwise preview.
  --remove               Select removal of proxy configuration; add --apply to
                         remove. Cannot be combined with proxy value options.
  --restartdaemons       Restart available selected services after apply/removal.
                         Requires --apply and a daemon target.
  --help                 Show this help.

Example:
  configure-proxy.sh --environment --profile --waagent \
    --daemons gpfs.service --http_proxy http://proxy.example:8080 \
    --https_proxy http://proxy.example:8080 \
    --no_proxy 'localhost,127.0.0.1,::1,169.254.169.254,168.63.129.16,.local'

Preview removal:
  configure-proxy.sh --alldefaults --remove
Apply removal:
  configure-proxy.sh --alldefaults --remove --apply

Configuration and removal preview by default, even as root. Add --apply to write.
The script writes both uppercase and lowercase variables. It manages only the
six proxy assignments in /etc/environment and its own named files elsewhere.
Named files use NAME.sh in /etc/profile.d, NAME in /etc/sudoers.d and NAME.conf
in each selected service's drop-in directory. Previews show the full paths.
Use the same --dropin-name for removal. Changing the name does not rename or
remove files created with another name; /etc/environment is independent of it.
Removal deletes current proxy assignments from /etc/environment, including
ones that existed before this script ran. It does not restore prior values.
Removal only deletes named files with the script's managed-file header.
Other configuration files and drop-ins are not removed.
Service selection checks unit availability, not whether the VM is in Azure.
For --daemons, --waagent and --alldefaults, unavailable or uninspectable services
warn and skip while other targets continue. Skipped drop-ins are left untouched.
If systemctl is unavailable, all service targets are skipped with warnings.
Systemd is reloaded when drop-ins change. Services are restarted only when
--restartdaemons is explicitly supplied; even unchanged selected services restart.
Review bypass matching for each client; CIDR support varies. URLs must not
contain credentials. Applying changes requires root; sudoers requires visudo.
Requires bash, awk, diff and standard Linux utilities.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

dropin_name_valid() {
  local LC_ALL=C value=$1
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ && ${#value} -le 250 ]]
}

decimal_in_range() {
  local LC_ALL=C value=$1 minimum=$2 maximum=$3
  [[ $value =~ ^[0-9]+$ ]] || return 1
  value=${value#"${value%%[!0]*}"}
  value=${value:-0}
  ((${#value} <= ${#maximum})) || return 1
  ((10#$value >= minimum && 10#$value <= maximum))
}

ipv4_valid() {
  local LC_ALL=C address=$1 octet
  local -a octets=()
  [[ $address =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    decimal_in_range "$octet" 0 255 || return 1
  done
}

ipv6_valid() {
  local LC_ALL=C address=$1 scope group compressed=false
  local -a groups=()
  if [[ $address == *%* ]]; then
    scope=${address#*%}
    [[ $scope =~ ^[A-Za-z0-9_.~-]+$ ]] || return 1
    address=${address%%\%*}
  fi
  [[ $address == *:* && $address != *[!0-9A-Fa-f:.]* && $address != *:::* ]] || return 1
  if [[ $address == *.* ]]; then
    ipv4_valid "${address##*:}" || return 1
    # An embedded IPv4 tail occupies two IPv6 groups.
    address="${address%:*}:0:0"
  fi
  if [[ $address == *::* ]]; then
    [[ ${address#*::} != *::* ]] || return 1
    compressed=true
    address=${address/::/:}
    address=${address#:}
    address=${address%:}
  else
    [[ $address != :* && $address != *: ]] || return 1
  fi
  if [[ -n $address ]]; then IFS=: read -r -a groups <<< "$address"; fi
  for group in "${groups[@]}"; do
    [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
  if $compressed; then ((${#groups[@]} < 8))
  else ((${#groups[@]} == 8)); fi
}

hostname_valid() {
  local LC_ALL=C value=$1 allow_suffix=${2:-false} label
  local -a labels=()
  if $allow_suffix; then value=${value#.}; fi
  value=${value%.}
  [[ -n $value && ${#value} -le 253 && $value != *. ]] || return 1
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

address_or_hostname() {
  if ipv4_valid "$1" || ipv6_valid "$1"; then return 0; fi
  [[ ! $1 =~ ^[0-9.]+$ ]] && hostname_valid "$1" "${2:-false}"
}

cidr_valid() {
  local value=$1 address prefix octet mask=0 inverse
  local -a octets=()
  [[ $value == */* && $value != */*/* ]] || return 1
  address=${value%/*}
  prefix=${value##*/}
  if ipv4_valid "$address"; then
    if [[ $prefix == *.* ]]; then
      ipv4_valid "$prefix" || return 1
      IFS=. read -r -a octets <<< "$prefix"
      for octet in "${octets[@]}"; do mask=$(((mask << 8) | 10#$octet)); done
      inverse=$((mask ^ 4294967295))
      # Dotted subnet masks and inverse host masks must have contiguous bits.
      (((mask & (mask + 1)) == 0 || (inverse & (inverse + 1)) == 0))
    else
      decimal_in_range "$prefix" 0 32
    fi
  elif ipv6_valid "$address"; then
    decimal_in_range "$prefix" 0 128
  else
    return 1
  fi
}

endpoint_valid() {
  local value=$1 allow_suffix=${2:-false} host suffix
  if [[ $value == \[* ]]; then
    [[ $value == *\]* ]] || return 1
    host=${value#\[}
    host=${host%%\]*}
    suffix=${value#*\]}
    ipv6_valid "$host" || return 1
  else
    host=${value%%:*}
    suffix=${value#"$host"}
    address_or_hostname "$host" "$allow_suffix" || return 1
  fi
  if [[ -n $suffix ]]; then
    [[ $suffix == :* ]] && decimal_in_range "${suffix#:}" 1 65535
  fi
}

proxy_url_valid() {
  local LC_ALL=C value=$1 authority
  [[ $value != *[![:graph:]]* && $value =~ ^[Hh][Tt][Tt][Pp][Ss]?://(.+)$ ]] || return 1
  authority=${BASH_REMATCH[1]}
  endpoint_valid "$authority"
}

validate_no_proxy() {
  local LC_ALL=C value=$1 entry
  local -a entries=()
  [[ -n $value && $value != '*' ]] || return 0
  [[ $value != *[![:graph:]]* && $value != ,* && $value != *, && $value != *,,* ]] ||
    fail 'no_proxy must contain nonempty, comma-separated entries without whitespace.'
  IFS=, read -r -a entries <<< "$value"
  for entry in "${entries[@]}"; do
    if [[ $entry == */* ]]; then
      cidr_valid "$entry" || fail "Invalid no_proxy CIDR: $entry"
    elif ipv4_valid "$entry" || ipv6_valid "$entry"; then
      continue
    else
      if [[ $entry == \[* && $entry == *%* ]]; then
        fail "Invalid no_proxy IPv6 entry: $entry"
      fi
      endpoint_valid "$entry" true || fail "Invalid no_proxy entry: $entry"
    fi
  done
}

environment=false profile=false sudoers=false waagent=false apply=false remove=false restart_daemons=false
dropin_name=90-explicit-proxy
http_set=false https_set=false no_set=false
http_proxy_value= https_proxy_value= no_proxy_value=
declare -a daemons=()
while (($#)); do
  case "$1" in
    --environment) environment=true; shift ;;
    --profile) profile=true; shift ;;
    --sudoers) sudoers=true; shift ;;
    --waagent) waagent=true; shift ;;
    --alldefaults) environment=true; profile=true; sudoers=true; waagent=true; shift ;;
    --apply) apply=true; shift ;;
    --remove) remove=true; shift ;;
    --restartdaemons) restart_daemons=true; shift ;;
    --help) usage; exit 0 ;;
    --http_proxy|--https_proxy|--no_proxy|--daemons|--dropin-name)
      option=$1
      (($# >= 2)) || fail "$option requires a value."
      case "$option" in
        --http_proxy) http_proxy_value=$2; http_set=true ;;
        --https_proxy) https_proxy_value=$2; https_set=true ;;
        --no_proxy) no_proxy_value=$2; no_set=true ;;
        --dropin-name) dropin_name=$2 ;;
        --daemons)
          [[ -n $2 && $2 != ,* && $2 != *, && $2 != *,,* ]] ||
            fail "--daemons requires a comma-separated list of service names."
          IFS=, read -r -a supplied_daemons <<< "$2"
          daemons+=("${supplied_daemons[@]}")
          ;;
      esac
      shift 2 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

$environment || $profile || $sudoers || $waagent || ((${#daemons[@]})) ||
  fail "Select at least one configuration target."
dropin_name_valid "$dropin_name" ||
  fail '--dropin-name must be a basename of 1-250 ASCII letters, digits, underscores or hyphens, starting with a letter or digit; no extension or directory.'
if $remove; then
  ! $http_set && ! $https_set && ! $no_set ||
    fail "Proxy value options cannot be combined with --remove."
else
  $http_set && $https_set && $no_set ||
    fail "Supply --http_proxy, --https_proxy and --no_proxy explicitly."
fi
if $restart_daemons; then
  $apply || fail "--restartdaemons requires --apply."
  $waagent || ((${#daemons[@]})) ||
    fail "--restartdaemons requires --waagent or --daemons."
fi
if ! $remove; then
  proxy_url_valid "$http_proxy_value" ||
    fail 'http_proxy must be http(s)://host[:port] without credentials or a path.'
  proxy_url_valid "$https_proxy_value" ||
    fail 'https_proxy must be http(s)://host[:port] without credentials or a path.'
  validate_no_proxy "$no_proxy_value"
fi

if $waagent; then daemons+=(waagent.service); fi
declare -a unique_daemons=()
for daemon in "${daemons[@]}"; do
  [[ $daemon =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*[.]service$ ]] ||
    fail "Invalid systemd service unit name: $daemon"
  duplicate=false
  for existing in "${unique_daemons[@]}"; do
    [[ $existing != "$daemon" ]] || duplicate=true
  done
  $duplicate || unique_daemons+=("$daemon")
done

declare -a available_daemons=()
for daemon in "${unique_daemons[@]}"; do
  if ! command -v systemctl >/dev/null; then
    warn "Skipping $daemon: systemctl is unavailable."
  elif ! state=$(systemctl show "$daemon" --property=LoadState --value 2>&1); then
    warn "Skipping $daemon: could not inspect the unit: $state"
  elif [[ $state != loaded ]]; then
    warn "Skipping $daemon: unit is unavailable (LoadState=$state)."
  else
    available_daemons+=("$daemon")
  fi
done

if ! $environment && ! $profile && ! $sudoers && ((${#available_daemons[@]} == 0)); then
  printf 'No applicable targets; no changes made.\n'
  exit 0
fi

if $apply; then
  ((EUID == 0)) || fail "Applying or removing configuration requires root."
  if $sudoers && ! $remove; then
    command -v visudo >/dev/null || fail "visudo is required to validate the sudoers file."
  fi
fi

render_variables() {
  printf 'http_proxy=%s\nhttps_proxy=%s\nno_proxy=%s\n' \
    "$http_proxy_value" "$https_proxy_value" "$no_proxy_value"
  printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' \
    "$http_proxy_value" "$https_proxy_value" "$no_proxy_value"
}

render_environment() {
  if [[ -f $1 ]]; then
    awk '!/^[[:space:]]*(export[[:space:]]+)?(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)[[:space:]]*=/' "$1"
  fi
  if ! $remove; then render_variables; fi
}

render_profile() {
  printf '# Managed by configure-proxy.sh\n'
  while IFS= read -r line; do printf "export %s='%s'\n" "${line%%=*}" "${line#*=}"; done \
    < <(render_variables)
}

render_sudoers() {
  printf '# Managed by configure-proxy.sh\n'
  printf 'Defaults env_keep += "http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"\n'
}

render_systemd() {
  printf '# Managed by configure-proxy.sh\n[Service]\n'
  while IFS= read -r line; do printf 'Environment="%s"\n' "$line"; done \
    < <(render_variables)
}

temporary=
cleanup() {
  if [[ -n $temporary && -f $temporary ]]; then rm -f -- "$temporary"; fi
}
trap cleanup EXIT

changed_systemd=false
process_target() {
  local target=$1 renderer=$2 mode=$3 old=/dev/null diff_status
  [[ ! -L $target ]] || fail "Refusing to replace symbolic link: $target"
  if [[ -e $target && ! -f $target ]]; then fail "Not a regular file: $target"; fi
  if [[ -f $target ]]; then
    [[ -r $target ]] || fail "Cannot read $target."
    old=$target
  fi
  printf '\n--- %s ---\n' "$target"
  if $remove && [[ $old == /dev/null ]]; then
    printf 'No change: file does not exist.\n'
    return
  fi
  if $remove && [[ $renderer != render_environment ]]; then
    local header
    IFS= read -r header < "$target" || fail "Cannot read managed-file header: $target"
    [[ $header == '# Managed by configure-proxy.sh' ]] ||
      fail "Refusing to remove a file without the managed-file header: $target"
    diff_status=0
    diff -u --label "current: $target" --label "removed: $target" "$target" /dev/null || diff_status=$?
    ((diff_status <= 1)) || fail "Could not compare $target."
    if ! $apply; then return; fi
    rm -- "$target" || fail "Could not remove $target."
    if [[ $renderer == render_systemd ]]; then changed_systemd=true; fi
    printf 'Removed %s\n' "$target"
    return
  fi
  diff_status=0
  diff -u --label "current: $target" --label "proposed: $target" "$old" \
    <("$renderer" "$target") || diff_status=$?
  ((diff_status <= 1)) || fail "Could not compare $target."
  if ((diff_status == 0)); then
    printf 'No change.\n'
    return
  fi
  if ! $apply; then return; fi
  install -d -m 0755 -- "$(dirname -- "$target")"
  temporary=$(mktemp "$(dirname -- "$target")/.explicit-proxy.XXXXXXXX")
  "$renderer" "$target" > "$temporary"
  if [[ $renderer == render_sudoers ]]; then
    visudo -c -f "$temporary" || fail "Proposed sudoers file did not pass visudo."
  fi
  if [[ -f $target && $renderer == render_environment ]]; then
    chmod --reference="$target" "$temporary"
    chown --reference="$target" "$temporary"
  else
    chmod "$mode" "$temporary"
    chown root:root "$temporary"
  fi
  mv -f -- "$temporary" "$target"
  temporary=
  if [[ $renderer == render_systemd ]]; then changed_systemd=true; fi
  if $remove; then printf 'Removed proxy assignments from %s\n' "$target"
  else printf 'Applied %s\n' "$target"; fi
}

if $remove && ! $apply; then
  printf 'Removal preview only; no files or services will be changed.\n'
elif $remove; then
  printf 'Removing selected configuration; an error can leave earlier targets updated.\n'
elif $apply; then
  printf 'Applying changes; an error can leave earlier targets updated.\n'
else
  printf 'Preview only; no files or services will be changed.\n'
fi
$environment && process_target /etc/environment render_environment 0644
$profile && process_target "/etc/profile.d/${dropin_name}.sh" render_profile 0644
$sudoers && process_target "/etc/sudoers.d/${dropin_name}" render_sudoers 0440
for daemon in "${available_daemons[@]}"; do
  process_target "/etc/systemd/system/${daemon}.d/${dropin_name}.conf" render_systemd 0644
done
if $changed_systemd; then
  systemctl daemon-reload || fail "systemd reload failed; written drop-ins remain on disk."
  printf '\nsystemd configuration reloaded.\n'
fi
if $restart_daemons; then
  for daemon in "${available_daemons[@]}"; do
    printf 'Restarting %s\n' "$daemon"
    systemctl restart "$daemon" || fail "Failed to restart $daemon; earlier changes remain applied."
  done
elif ((${#available_daemons[@]})); then
  printf '\nServices were not restarted; review and restart them when safe.\n'
fi
printf '\nNew login/session and sudo settings take effect according to their normal lifecycle.\n'
 
