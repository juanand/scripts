#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
(($# <= 1)) || fail 'Usage: test-removal.sh [case-name-pattern]'
filter=${1:-*}
script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/configure-proxy.sh"
test_root=$(mktemp -d /tmp/configure-proxy-removal.XXXXXXXX)
readonly test_root
fixture_script="$test_root/configure-proxy.sh"
environment_file="$test_root/etc/environment"
managed_files=(
  "$test_root/etc/profile.d/90-explicit-proxy.sh"
  "$test_root/etc/sudoers.d/90-explicit-proxy"
  "$test_root/etc/systemd/system/waagent.service.d/90-explicit-proxy.conf"
)
custom_name=70-team_proxy
custom_files=(
  "$test_root/etc/profile.d/$custom_name.sh"
  "$test_root/etc/sudoers.d/$custom_name"
  "$test_root/etc/systemd/system/waagent.service.d/$custom_name.conf"
)
extra_file="$test_root/etc/systemd/system/other.service.d/90-explicit-proxy.conf"
alternate_agent_file="$test_root/etc/systemd/system/walinuxagent.service.d/90-explicit-proxy.conf"
custom_alternate_agent_file="$test_root/etc/systemd/system/walinuxagent.service.d/$custom_name.conf"
manager_file="$test_root/etc/systemd/system.conf.d/90-explicit-proxy.conf"
custom_manager_file="$test_root/etc/systemd/system.conf.d/$custom_name.conf"
unrelated_manager_file="$test_root/etc/systemd/system.conf.d/10-unrelated.conf"
directories=(
  "$test_root/etc/systemd/system/waagent.service.d"
  "$test_root/etc/systemd/system/walinuxagent.service.d"
  "$test_root/etc/systemd/system/other.service.d"
  "$test_root/etc/systemd/system.conf.d"
  "$test_root/etc/systemd/system" "$test_root/etc/systemd"
  "$test_root/etc/profile.d" "$test_root/etc/sudoers.d" "$test_root/etc"
  "$test_root/bin" "$test_root"
)
tools=(bash cat diff awk dirname install mktemp chmod mv rm)
cleanup() {
  local tool directory
  rm -f -- "$fixture_script" "$environment_file" "${managed_files[@]}" "${custom_files[@]}" "$extra_file" \
    "$alternate_agent_file" "$custom_alternate_agent_file" \
    "$manager_file" "$custom_manager_file" "$unrelated_manager_file" \
    "$test_root/stdout" "$test_root/stderr" "$test_root/systemctl.log" "$test_root/manager-queries.log" \
    "$test_root/bin/chown" "$test_root/bin/systemctl" "$test_root/bin/visudo" "$test_root/systemctl.disabled"
  for tool in "${tools[@]}"; do rm -f -- "$test_root/bin/$tool"; done
  for directory in "${directories[@]}"; do
    if [[ -d $directory ]]; then rmdir -- "$directory"; fi
  done
}
trap cleanup EXIT
mkdir -p -- "${directories[@]}"
for tool in "${tools[@]}"; do
  executable=$(command -v "$tool") || fail "$tool is required."
  ln -s -- "$executable" "$test_root/bin/$tool"
done

# Test a private copy: redirect fixed system paths and simulate only the UID.
contents=$(<"$script_path")
[[ $contents == *'((EUID == 0))'* ]] || fail 'Cannot locate the privilege check for the fixture.'
contents=${contents//\/etc\//"$test_root/etc/"}
contents=${contents/'((EUID == 0))'/'((FIXTURE_EUID == 0))'}
printf '%s\n' "$contents" > "$fixture_script"
cat > "$test_root/bin/chown" <<'STUB'
#!/usr/bin/env bash
[[ ${!#} == "$FIXTURE_ROOT/"* ]] || { printf 'Blocked non-fixture chown.\n' >&2; exit 99; }
STUB
cat > "$test_root/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'show waagent.service --property=LoadState --value') state=$FIXTURE_WAAGENT_STATE ;;
  'show walinuxagent.service --property=LoadState --value') state=$FIXTURE_WALINUXAGENT_STATE ;;
  'show waagent.service --property=Id --value') state=$FIXTURE_WAAGENT_ID ;;
  'show walinuxagent.service --property=Id --value') state=$FIXTURE_WALINUXAGENT_ID ;;
  'show other.service --property=LoadState --value') state=$FIXTURE_OTHER_STATE ;;
  'show --property=Version --value')
    printf 'query\n' >> "$FIXTURE_ROOT/manager-queries.log"
    state=$FIXTURE_MANAGER_STATE ;;
  'daemon-reload')
    printf '%s\n' "$*" >> "$FIXTURE_ROOT/systemctl.log"
    case "$FIXTURE_RELOAD_MODE" in
      warning) printf 'systemd-rc-local-generator: /etc/rc.local is not marked executable, skipping.\n' >&2 ;;
      failure) printf 'Fixture reload failed.\n' >&2; exit 1 ;;
    esac
    exit 0 ;;
  'restart waagent.service'|'restart walinuxagent.service'|'restart other.service')
    printf '%s\n' "$*" >> "$FIXTURE_ROOT/systemctl.log"; exit 0 ;;
  *) printf 'Blocked unexpected systemctl command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ $state == error ]]; then
  printf 'Fixture service manager is unavailable.\n' >&2
  exit 1
fi
if [[ $state == not-found-error ]]; then
  printf 'not-found\n'
  exit 1
fi
printf '%s\n' "$state"
STUB
cat > "$test_root/bin/visudo" <<'STUB'
#!/usr/bin/env bash
[[ $# == 3 && $1 == -c && $2 == -f && $3 == "$FIXTURE_ROOT/"* && -f $3 ]] ||
  { printf 'Blocked non-fixture visudo.\n' >&2; exit 99; }
STUB
chmod +x -- "$test_root/bin/chown" "$test_root/bin/systemctl" "$test_root/bin/visudo"

environment_before=$'KEEP_ME=1\nhttp_proxy=http://old.example:8080\nHTTPS_PROXY=http://old.example:8080\nNO_PROXY=localhost\nALSO_KEEP=value'
environment_after=$'KEEP_ME=1\nALSO_KEEP=value'
managed_before=$'# Managed by configure-proxy.sh\nold proxy configuration'
configuration_args=(--http_proxy http://new.example:8080 --https_proxy http://new.example:8443 --no_proxy localhost)
configured_environment="$environment_after"$'\nhttp_proxy=http://new.example:8080\nhttps_proxy=http://new.example:8443\nno_proxy=localhost\nHTTP_PROXY=http://new.example:8080\nHTTPS_PROXY=http://new.example:8443\nNO_PROXY=localhost'
configured_manager=$'# Managed by configure-proxy.sh\n[Manager]\nDefaultEnvironment="http_proxy=http://new.example:8080"\nDefaultEnvironment="https_proxy=http://new.example:8443"\nDefaultEnvironment="no_proxy=localhost"\nDefaultEnvironment="HTTP_PROXY=http://new.example:8080"\nDefaultEnvironment="HTTPS_PROXY=http://new.example:8443"\nDefaultEnvironment="NO_PROXY=localhost"'
unrelated_manager_before=$'[Manager]\nDefaultEnvironment="UNRELATED=keep"'
passed=0

matches_filter() {
  # The optional case selector is intentionally a Bash glob.
  # shellcheck disable=SC2053
  [[ $1 == $filter ]]
}

seed_files() {
  local file
  fixture_waagent_state=loaded
  fixture_walinuxagent_state=not-found
  fixture_waagent_id=waagent.service
  fixture_walinuxagent_id=walinuxagent.service
  fixture_other_state=loaded
  fixture_manager_state=fixture-version
  fixture_reload_mode=success
  rm -f -- "$environment_file" "${managed_files[@]}" "${custom_files[@]}" "$extra_file" \
    "$alternate_agent_file" "$custom_alternate_agent_file" \
    "$manager_file" "$custom_manager_file"
  printf '%s\n' "$environment_before" > "$environment_file"
  for file in "${managed_files[@]}"; do printf '%s\n' "$managed_before" > "$file"; done
  printf '%s\n' "$unrelated_manager_before" > "$unrelated_manager_file"
}

run_script() {
  local uid=$1
  shift
  : > "$test_root/systemctl.log"
  : > "$test_root/manager-queries.log"
  status=0
  FIXTURE_EUID="$uid" FIXTURE_ROOT="$test_root" \
    FIXTURE_WAAGENT_STATE="$fixture_waagent_state" FIXTURE_OTHER_STATE="$fixture_other_state" \
    FIXTURE_WALINUXAGENT_STATE="$fixture_walinuxagent_state" \
    FIXTURE_WAAGENT_ID="$fixture_waagent_id" FIXTURE_WALINUXAGENT_ID="$fixture_walinuxagent_id" \
    FIXTURE_MANAGER_STATE="$fixture_manager_state" FIXTURE_RELOAD_MODE="$fixture_reload_mode" PATH="$test_root/bin" \
    "$BASH" "$fixture_script" "$@" > "$test_root/stdout" 2> "$test_root/stderr" || status=$?
  output=$(<"$test_root/stdout")
  errors=$(<"$test_root/stderr")
}

assert_success() {
  [[ $status == 0 && -z $errors ]] || fail "status=$status: $errors"
}

assert_daemon_warning() {
  local unit=$1
  [[ $status == 0 && $errors == *'WARNING: '* && $errors == *"$unit"* && $errors != *'ERROR: '* ]] ||
    fail "Expected a nonfatal warning for $unit, got status=$status: $errors"
}

assert_nonwaagent_configuration() {
  [[ $(<"$environment_file") == "$configured_environment" ]] || fail 'Environment configuration did not apply.'
  [[ $(<"${managed_files[0]}") == *"export http_proxy='http://new.example:8080'"* ]] ||
    fail 'Profile configuration did not apply.'
  [[ $(<"${managed_files[1]}") == *'Defaults env_keep +='* ]] || fail 'Sudoers configuration did not apply.'
  [[ $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'Unavailable waagent configuration changed.'
  [[ ! -s $test_root/systemctl.log ]] || fail 'Unexpected service operation for unavailable waagent.'
}

assert_unchanged() {
  local file
  [[ $(<"$environment_file") == "$environment_before" ]] || fail 'Environment file changed.'
  for file in "${managed_files[@]}"; do
    [[ -f $file && $(<"$file") == "$managed_before" ]] || fail "Managed file changed: $file"
  done
  [[ ! -s $test_root/systemctl.log ]] || fail 'Unexpected service operation.'
}

assert_removed() {
  local file
  [[ $(<"$environment_file") == "$environment_after" ]] || fail 'Removal did not retain only unrelated settings.'
  for file in "${managed_files[@]}"; do
    [[ ! -e $file && ! -L $file ]] || fail "Managed file was not removed: $file"
  done
}

assert_manager_configuration() {
  local target=${1:-$manager_file}
  [[ -f $target && $(<"$target") == "$configured_manager" ]] || fail "Unexpected manager configuration: $target"
  [[ $(<"$unrelated_manager_file") == "$unrelated_manager_before" ]] || fail 'Unrelated manager settings changed.'
}

pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

for uid in 1000 0; do
  name="removal preview at UID $uid"
  if matches_filter "$name"; then
    seed_files
    run_script "$uid" --alldefaults --remove
    assert_success
    [[ $output == *'Removal preview only;'* ]] || fail 'Expected removal preview output.'
    for file in "${managed_files[@]}"; do
      [[ $output == *"--- $file ---"* ]] || fail "Preview did not show the default filename: $file"
    done
    assert_unchanged
    pass "$name"
  fi
done

if matches_filter 'removal apply requires root'; then
  seed_files
  run_script 1000 --alldefaults --remove --apply
  [[ $status == 1 && $errors == *'requires root'* ]] || fail "Expected root requirement: $errors"
  assert_unchanged
  pass 'removal apply requires root'
fi

if matches_filter 'removal apply and repeated apply'; then
  seed_files
  run_script 0 --alldefaults --remove --apply
  assert_success
  assert_removed
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Expected reload without restart.'
  run_script 0 --alldefaults --remove --apply
  assert_success
  assert_removed
  [[ ! -s $test_root/systemctl.log ]] || fail 'Unchanged removal reloaded services.'
  pass 'removal apply and repeated apply'
fi

if matches_filter 'removal restart requires apply'; then
  seed_files
  run_script 0 --alldefaults --remove --restartdaemons
  [[ $status == 1 && $errors == *'requires --apply'* ]] || fail "Expected apply requirement: $errors"
  assert_unchanged
  pass 'removal restart requires apply'
fi

if matches_filter 'removal apply with restart'; then
  seed_files
  run_script 0 --alldefaults --remove --apply --restartdaemons
  assert_success
  assert_removed
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart waagent.service' ]] ||
    fail 'Expected reload followed by an explicitly requested restart.'
  pass 'removal apply with restart'
fi

if matches_filter 'configuration apply remains supported'; then
  seed_files
  run_script 0 --environment --profile --waagent --apply \
    --http_proxy http://new.example:8080 --https_proxy http://new.example:8443 --no_proxy localhost
  assert_success
  [[ $(<"$environment_file") == "$environment_after"$'\nhttp_proxy=http://new.example:8080\nhttps_proxy=http://new.example:8443\nno_proxy=localhost\nHTTP_PROXY=http://new.example:8080\nHTTPS_PROXY=http://new.example:8443\nNO_PROXY=localhost' ]] ||
    fail 'Configuration apply did not write the expected proxy settings.'
  [[ $(<"${managed_files[0]}") == *"export http_proxy='http://new.example:8080'"* ]] ||
    fail 'Configuration apply did not update the profile.'
  [[ $(<"${managed_files[2]}") == *'Environment="http_proxy=http://new.example:8080"'* ]] ||
    fail 'Configuration apply did not update the drop-in.'
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Unexpected service operations.'
  pass 'configuration apply remains supported'
fi

if matches_filter 'removal rejects proxy values'; then
  seed_files
  run_script 0 --alldefaults --remove --apply --http_proxy http://proxy.example:8080
  [[ $status == 1 && $errors == *'Proxy value options cannot be combined with --remove.'* ]] ||
    fail "Expected conflicting values to fail: $errors"
  assert_unchanged
  pass 'removal rejects proxy values'
fi

if matches_filter 'obsolete preview flag is rejected'; then
  seed_files
  run_script 0 --alldefaults --remove --preview
  [[ $status == 1 && $errors == *'Unknown option: --preview'* ]] || fail "Expected obsolete flag rejection: $errors"
  assert_unchanged
  pass 'obsolete preview flag is rejected'
fi

for state in not-found masked error; do
  name="alldefaults skips unavailable waagent: $state"
  if matches_filter "$name"; then
    seed_files
    fixture_waagent_state=$state
    run_script 0 --alldefaults --apply --restartdaemons "${configuration_args[@]}"
    assert_daemon_warning waagent.service
    assert_nonwaagent_configuration
    pass "$name"
  fi
done

if matches_filter 'missing systemctl skips all daemon targets'; then
  seed_files
  mv -- "$test_root/bin/systemctl" "$test_root/systemctl.disabled"
  run_script 0 --alldefaults --daemons other.service --apply --restartdaemons "${configuration_args[@]}"
  mv -- "$test_root/systemctl.disabled" "$test_root/bin/systemctl"
  assert_daemon_warning waagent.service
  assert_daemon_warning other.service
  assert_nonwaagent_configuration
  [[ ! -e $extra_file ]] || fail 'Unavailable named service received a drop-in.'
  pass 'missing systemctl skips all daemon targets'
fi

if matches_filter 'missing waagent does not block extra services'; then
  seed_files
  fixture_waagent_state=not-found
  run_script 0 --environment --waagent --daemons other.service --apply --restartdaemons "${configuration_args[@]}"
  assert_daemon_warning waagent.service
  [[ $(<"$environment_file") == "$configured_environment" ]] || fail 'Environment configuration did not apply.'
  [[ $(<"$extra_file") == *'Environment="http_proxy=http://new.example:8080"'* ]] ||
    fail 'Extra service configuration did not apply.'
  [[ $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'Unavailable waagent configuration changed.'
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart other.service' ]] ||
    fail 'Unexpected service operations after skipping waagent.'
  pass 'missing waagent does not block extra services'
fi

if matches_filter 'missing waagent alone is a no-op'; then
  seed_files
  fixture_waagent_state=not-found
  run_script 1000 --waagent --remove --apply
  assert_daemon_warning waagent.service
  [[ $output == *'No applicable targets; no changes made.'* ]] || fail 'Expected an explicit no-op.'
  assert_unchanged
  pass 'missing waagent alone is a no-op'
fi

if matches_filter 'named waagent is optional and deduplicated'; then
  seed_files
  fixture_waagent_state=not-found
  run_script 0 --alldefaults --daemons waagent.service,waagent.service --daemons waagent.service --apply "${configuration_args[@]}"
  assert_daemon_warning waagent.service
  [[ $errors != *$'\n'* ]] || fail 'Duplicate requests produced multiple warnings.'
  assert_nonwaagent_configuration
  pass 'named waagent is optional and deduplicated'
fi

if matches_filter 'alternate agent preview apply and removal'; then
  seed_files
  fixture_waagent_state=not-found
  fixture_walinuxagent_state=loaded
  run_script 1000 --waagent --dropin-name "$custom_name" "${configuration_args[@]}"
  assert_success
  [[ $output == *"--- $custom_alternate_agent_file ---"* && ! -e $custom_alternate_agent_file ]] ||
    fail 'Alternate agent preview did not use the selected unit and custom filename.'
  assert_unchanged
  run_script 0 --alldefaults --dropin-name "$custom_name" --apply --restartdaemons "${configuration_args[@]}"
  assert_success
  [[ $(<"$custom_alternate_agent_file") == *'Environment="http_proxy=http://new.example:8080"'* ]] ||
    fail 'Alternate agent configuration did not apply.'
  [[ ! -e ${custom_files[2]} && $(<"${managed_files[2]}") == "$managed_before" ]] ||
    fail 'Automatic fallback changed the other agent name.'
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart walinuxagent.service' ]] ||
    fail 'Fallback did not restart only the selected agent.'
  run_script 0 --alldefaults --dropin-name "$custom_name" --remove --apply --restartdaemons
  assert_success
  [[ ! -e $custom_alternate_agent_file && ! -e ${custom_files[0]} && ! -e ${custom_files[1]} ]] ||
    fail 'Removal did not use the resolved agent and selected filename.'
  [[ $(<"$environment_file") == "$environment_after" &&
     $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'Fallback removal changed unrelated configuration.'
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart walinuxagent.service' ]] ||
    fail 'Fallback removal restarted the wrong agent.'
  pass 'alternate agent preview apply and removal'
fi

for selection in automatic explicit; do
  name="agent aliases share one target: $selection"
  if matches_filter "$name"; then
    seed_files
    fixture_walinuxagent_state=loaded
    fixture_waagent_id=walinuxagent.service
    agent_args=(--waagent)
    if [[ $selection == explicit ]]; then
      agent_args+=(--daemons walinuxagent.service)
      selected_agent=walinuxagent.service
      selected_agent_file=$alternate_agent_file
    else
      selected_agent=waagent.service
      selected_agent_file=${managed_files[2]}
    fi
    run_script 0 "${agent_args[@]}" --apply --restartdaemons "${configuration_args[@]}"
    assert_success
    [[ $(<"$selected_agent_file") == *'Environment="http_proxy=http://new.example:8080"'* ]] ||
      fail 'Alias resolution did not configure the selected path.'
    if [[ $selection == explicit ]]; then
      [[ $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'An implicit alias duplicated the explicit target.'
    else
      [[ ! -e $alternate_agent_file ]] || fail 'Automatic alias resolution created two drop-ins.'
    fi
    [[ $(<"$test_root/systemctl.log") == "daemon-reload"$'\n'"restart $selected_agent" ]] ||
      fail 'An aliased agent was restarted more than once or through the wrong selection.'
    pass "$name"
  fi
done

if matches_filter 'distinct agent units require explicit selection'; then
  seed_files
  fixture_walinuxagent_state=loaded
  run_script 0 --alldefaults --apply --restartdaemons "${configuration_args[@]}"
  assert_daemon_warning '--waagent'
  [[ $errors == *'different available units'* && $errors == *'--daemons'* ]] ||
    fail 'Ambiguous agent warning did not explain explicit selection.'
  assert_nonwaagent_configuration
  [[ ! -e $alternate_agent_file ]] || fail 'Ambiguous agent was configured automatically.'
  run_script 0 --alldefaults --daemons walinuxagent.service --apply --restartdaemons "${configuration_args[@]}"
  assert_daemon_warning '--waagent'
  [[ $(<"$alternate_agent_file") == *'Environment="http_proxy=http://new.example:8080"'* &&
     $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'Explicit agent choice was not respected.'
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart walinuxagent.service' ]] ||
    fail 'Ambiguity blocked or broadened an explicit restart.'
  pass 'distinct agent units require explicit selection'
fi

for identity in error '' invalid-identity; do
  name="unverified agent identity skips automatic selection: ${identity:-empty}"
  if matches_filter "$name"; then
    seed_files
    fixture_walinuxagent_state=loaded
    fixture_waagent_id=$identity
    fixture_walinuxagent_id=$identity
    run_script 0 --environment --waagent --apply "${configuration_args[@]}"
    assert_daemon_warning '--waagent'
    [[ $errors == *'--daemons'* && ! -e $alternate_agent_file &&
       $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'Unverified identities were treated as matching aliases.'
    [[ $(<"$environment_file") == "$configured_environment" && ! -s $test_root/systemctl.log ]] ||
      fail 'Identity failure blocked other targets or caused service operations.'
    pass "$name"
  fi
done

for probe_state in error ''; do
  name="failed agent probe remains visible with fallback: ${probe_state:-empty}"
  if matches_filter "$name"; then
    seed_files
    fixture_waagent_state=$probe_state
    fixture_walinuxagent_state=loaded
    run_script 0 --waagent --apply --restartdaemons "${configuration_args[@]}"
    assert_daemon_warning waagent.service
    [[ $(<"$alternate_agent_file") == *'Environment="http_proxy=http://new.example:8080"'* &&
       $(<"${managed_files[2]}") == "$managed_before" ]] || fail 'The confirmed available fallback was not selected.'
    [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart walinuxagent.service' ]] ||
      fail 'Probe failure caused incorrect service operations.'
    pass "$name"
  fi
done

if matches_filter 'not-found exit status permits agent fallback'; then
  seed_files
  fixture_waagent_state=not-found-error
  fixture_walinuxagent_state=loaded
  run_script 1000 --waagent "${configuration_args[@]}"
  assert_success
  [[ $output == *"--- $alternate_agent_file ---"* && ! -e $alternate_agent_file ]] ||
    fail 'Expected an alternate-agent preview after a not-found reply.'
  assert_unchanged
  pass 'not-found exit status permits agent fallback'
fi

for state in not-found masked error; do
  name="named daemons skip unavailable unit: $state"
  if matches_filter "$name"; then
    seed_files
    fixture_other_state=$state
    run_script 0 --environment --daemons other.service,waagent.service --apply --restartdaemons "${configuration_args[@]}"
    assert_daemon_warning other.service
    [[ $(<"$environment_file") == "$configured_environment" ]] || fail 'Environment configuration did not apply.'
    [[ $(<"${managed_files[2]}") == *'Environment="http_proxy=http://new.example:8080"'* ]] ||
      fail 'Available named service did not receive a drop-in.'
    [[ ! -e $extra_file ]] || fail 'Unavailable named service received a drop-in.'
    [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart waagent.service' ]] ||
      fail 'Unexpected service operations for mixed daemon availability.'
    pass "$name"
  fi
done

if matches_filter 'missing named daemon alone is a no-op'; then
  seed_files
  fixture_other_state=not-found
  run_script 1000 --daemons other.service --remove --apply
  assert_daemon_warning other.service
  [[ $output == *'No applicable targets; no changes made.'* ]] || fail 'Expected an explicit no-op.'
  [[ ! -e $extra_file ]] || fail 'Unavailable named service received a drop-in.'
  assert_unchanged
  pass 'missing named daemon alone is a no-op'
fi

if matches_filter 'removal skips unavailable named daemon'; then
  seed_files
  printf '%s\n' "$managed_before" > "$extra_file"
  fixture_other_state=not-found
  run_script 0 --environment --daemons other.service,waagent.service --remove --apply --restartdaemons
  assert_daemon_warning other.service
  [[ $(<"$environment_file") == "$environment_after" ]] || fail 'Environment removal did not apply.'
  [[ ! -e ${managed_files[2]} ]] || fail 'Available service drop-in was not removed.'
  [[ $(<"$extra_file") == "$managed_before" ]] || fail 'Unavailable service drop-in was modified.'
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart waagent.service' ]] ||
    fail 'Unexpected service operations during removal.'
  pass 'removal skips unavailable named daemon'
fi

check_invalid_daemons() {
  local name=$1 value=$2 expected_error=$3
  matches_filter "$name" || return 0
  seed_files
  run_script 0 --environment --daemons "$value" --apply "${configuration_args[@]}"
  [[ $status == 1 && $errors == *"ERROR: "*"${expected_error}"* ]] ||
    fail "Expected invalid daemon selection to fail: $errors"
  assert_unchanged
  pass "$name"
}

while IFS='|' read -r name value expected_error; do
  check_invalid_daemons "$name" "$value" "$expected_error"
done <<'CASES'
reject empty daemon list||--daemons requires a comma-separated list
reject empty daemon entry|other.service,,waagent.service|--daemons requires a comma-separated list
reject daemon path traversal|../other.service|Invalid systemd service unit name
reject daemon without service suffix|other|Invalid systemd service unit name
CASES

if matches_filter 'obsolete extradaemons flag is rejected'; then
  seed_files
  run_script 0 --environment --extradaemons other.service --apply "${configuration_args[@]}"
  [[ $status == 1 && $errors == *'Unknown option: --extradaemons'* ]] || fail "Expected obsolete flag rejection: $errors"
  assert_unchanged
  pass 'obsolete extradaemons flag is rejected'
fi

if matches_filter 'custom names appear in preview'; then
  seed_files
  run_script 1000 --alldefaults --dropin-name "$custom_name" "${configuration_args[@]}"
  assert_success
  for file in "${custom_files[@]}"; do
    [[ $output == *"--- $file ---"* && ! -e $file ]] || fail "Custom filename preview failed: $file"
  done
  assert_unchanged
  pass 'custom names appear in preview'
fi

if matches_filter 'custom names apply and remove only selected files'; then
  seed_files
  run_script 0 --alldefaults --dropin-name "$custom_name" --apply "${configuration_args[@]}"
  assert_success
  [[ $(<"$environment_file") == "$configured_environment" ]] || fail 'Environment configuration did not apply.'
  [[ $(<"${custom_files[0]}") == *"export http_proxy='http://new.example:8080'"* ]] || fail 'Custom profile not written.'
  [[ $(<"${custom_files[1]}") == *'Defaults env_keep +='* ]] || fail 'Custom sudoers file not written.'
  [[ $(<"${custom_files[2]}") == *'Environment="http_proxy=http://new.example:8080"'* ]] || fail 'Custom drop-in not written.'
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Custom drop-in did not request a reload.'
  run_script 0 --alldefaults --dropin-name "$custom_name" --remove --apply
  assert_success
  [[ $(<"$environment_file") == "$environment_after" ]] || fail 'Unrelated environment settings were not retained.'
  for file in "${custom_files[@]}"; do [[ ! -e $file ]] || fail "Custom file not removed: $file"; done
  for file in "${managed_files[@]}"; do
    [[ $(<"$file") == "$managed_before" ]] || fail "Default-named file changed: $file"
  done
  pass 'custom names apply and remove only selected files'
fi

check_invalid_name() {
  local name=$1 value=$2
  matches_filter "$name" || return 0
  seed_files
  run_script 0 --alldefaults --dropin-name "$value" --apply "${configuration_args[@]}"
  [[ $status == 1 && $errors == *'ERROR: '*'--dropin-name'* ]] || fail "Expected an invalid basename error: $errors"
  assert_unchanged
  pass "$name"
}

while IFS='|' read -r name value; do check_invalid_name "$name" "$value"; done <<'CASES'
reject empty basename|
reject path traversal|../escape
reject absolute basename|/absolute
reject basename extension|custom.conf
reject basename whitespace|custom name
reject leading dash|-custom
CASES
printf -v long_name '%0251d' 0
check_invalid_name 'reject basename over 250 characters' "$long_name"

if matches_filter 'accept 250-character basename'; then
  seed_files
  printf -v long_name '%0250d' 0
  run_script 1000 --waagent --dropin-name "$long_name" "${configuration_args[@]}"
  assert_success
  [[ $output == *"/$long_name.conf ---"* ]] || fail 'Maximum-length basename was not shown in preview.'
  assert_unchanged
  pass 'accept 250-character basename'
fi

for uid in 1000 0; do
  name="manager preview at UID $uid"
  if matches_filter "$name"; then
    seed_files
    run_script "$uid" --systemd-manager "${configuration_args[@]}"
    assert_success
    [[ $output == *"--- $manager_file ---"* && $output == *'[Manager]'* &&
       $output == *'DefaultEnvironment="http_proxy=http://new.example:8080"'* &&
       $output == *'defaults for newly started service processes'* ]] || fail 'Manager preview is incomplete.'
    [[ ! -e $manager_file ]] || fail 'Preview created the manager drop-in.'
    assert_unchanged
    pass "$name"
  fi
done

if matches_filter 'manager apply requires root'; then
  seed_files
  run_script 1000 --systemd-manager --apply "${configuration_args[@]}"
  [[ $status == 1 && $errors == *'requires root'* ]] || fail "Expected root requirement: $errors"
  [[ ! -e $manager_file ]] || fail 'Non-root apply created a manager drop-in.'
  assert_unchanged
  pass 'manager apply requires root'
fi

if matches_filter 'manager apply and removal are idempotent'; then
  seed_files
  run_script 0 --systemd-manager --apply "${configuration_args[@]}"
  assert_success
  assert_manager_configuration
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Manager apply did not reload exactly once.'
  run_script 0 --systemd-manager --apply "${configuration_args[@]}"
  assert_success
  assert_manager_configuration
  assert_unchanged
  run_script 1000 --systemd-manager --remove
  assert_success
  assert_manager_configuration
  assert_unchanged
  run_script 0 --systemd-manager --remove --apply
  assert_success
  [[ ! -e $manager_file && $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Manager removal did not reload.'
  [[ $(<"$unrelated_manager_file") == "$unrelated_manager_before" ]] || fail 'Removal changed unrelated manager settings.'
  run_script 0 --systemd-manager --remove --apply
  assert_success
  assert_unchanged
  pass 'manager apply and removal are idempotent'
fi

if matches_filter 'manager custom filename and protected removal'; then
  seed_files
  printf '%s\n' "$configured_manager" > "$manager_file"
  run_script 1000 --systemd-manager --dropin-name "$custom_name" "${configuration_args[@]}"
  assert_success
  [[ $output == *"--- $custom_manager_file ---"* && ! -e $custom_manager_file ]] ||
    fail 'Custom manager filename preview failed.'
  assert_unchanged
  run_script 0 --systemd-manager --dropin-name "$custom_name" --apply "${configuration_args[@]}"
  assert_success
  assert_manager_configuration "$custom_manager_file"
  run_script 0 --systemd-manager --dropin-name "$custom_name" --remove --apply
  assert_success
  [[ ! -e $custom_manager_file ]] || fail 'Custom manager file was not removed.'
  assert_manager_configuration
  printf '%s\n' "$unrelated_manager_before" > "$custom_manager_file"
  run_script 0 --systemd-manager --dropin-name "$custom_name" --remove --apply
  [[ $status == 1 && $errors == *'without the managed-file header'* ]] || fail 'Unmanaged manager file was not protected.'
  [[ $(<"$custom_manager_file") == "$unrelated_manager_before" ]] || fail 'Unmanaged manager file was modified.'
  assert_unchanged
  pass 'manager custom filename and protected removal'
fi

if matches_filter 'alldefaults does not select manager defaults'; then
  seed_files
  printf '%s\n' "$unrelated_manager_before" > "$manager_file"
  run_script 0 --alldefaults --apply "${configuration_args[@]}"
  assert_success
  [[ $(<"$manager_file") == "$unrelated_manager_before" && ! -s $test_root/manager-queries.log ]] ||
    fail 'alldefaults selected the manager target.'
  [[ $(<"$environment_file") == "$configured_environment" &&
     $(<"${managed_files[0]}") == *"export http_proxy='http://new.example:8080'"* &&
     $(<"${managed_files[1]}") == *'Defaults env_keep +='* ]] ||
    fail 'alldefaults did not retain environment/profile/sudoers targets.'
  pass 'alldefaults does not select manager defaults'
fi

for target in profile sudoers; do
  name="manager with independent $target target"
  if matches_filter "$name"; then
    seed_files
    run_script 0 --systemd-manager "--$target" --apply "${configuration_args[@]}"
    assert_success
    assert_manager_configuration
    [[ $(<"$environment_file") == "$environment_before" && $(<"${managed_files[2]}") == "$managed_before" ]] ||
      fail 'An unselected environment/service target changed.'
    if [[ $target == profile ]]; then
      [[ $(<"${managed_files[0]}") == *"export http_proxy='http://new.example:8080'"* &&
         $(<"${managed_files[1]}") == "$managed_before" ]] || fail 'Profile selection affected sudoers.'
    else
      [[ $(<"${managed_files[1]}") == *'Defaults env_keep +='* &&
         $(<"${managed_files[0]}") == "$managed_before" ]] || fail 'Sudoers selection affected profile.'
    fi
    [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Unexpected service operations.'
    pass "$name"
  fi
done

for state in error ''; do
  name="unavailable manager does not block profile: ${state:-empty reply}"
  if matches_filter "$name"; then
    seed_files
    fixture_manager_state=$state
    run_script 0 --systemd-manager --profile --apply "${configuration_args[@]}"
    assert_daemon_warning 'systemd manager'
    [[ ! -e $manager_file && ! -s $test_root/systemctl.log ]] || fail 'Unavailable manager was changed.'
    [[ $(<"${managed_files[0]}") == *"export http_proxy='http://new.example:8080'"* &&
       $(<"$environment_file") == "$environment_before" &&
       $(<"${managed_files[1]}") == "$managed_before" ]] || fail 'Profile-only behavior changed.'
    pass "$name"
  fi
done

if matches_filter 'manager without systemctl is a no-op'; then
  seed_files
  printf '%s\n' "$configured_manager" > "$manager_file"
  mv -- "$test_root/bin/systemctl" "$test_root/systemctl.disabled"
  run_script 1000 --systemd-manager --remove --apply
  mv -- "$test_root/systemctl.disabled" "$test_root/bin/systemctl"
  assert_daemon_warning 'systemd manager'
  [[ $output == *'No applicable targets; no changes made.'* ]] || fail 'Expected manager no-op.'
  assert_manager_configuration
  assert_unchanged
  pass 'manager without systemctl is a no-op'
fi

if matches_filter 'manager-only selection cannot restart all services'; then
  seed_files
  run_script 0 --systemd-manager --apply --restartdaemons "${configuration_args[@]}"
  [[ $status == 1 && $errors == *'requires --waagent or --daemons'* ]] || fail 'Manager selection authorized blanket restarts.'
  [[ ! -e $manager_file ]] || fail 'Rejected restart request changed manager configuration.'
  assert_unchanged
  pass 'manager-only selection cannot restart all services'
fi

if matches_filter 'systemd renderers preserve literal percent and empty bypass'; then
  seed_files
  run_script 0 --systemd-manager --waagent --apply \
    --http_proxy 'http://[fe80::1%25eth0]:3128' --https_proxy 'http://[fe80::1%25eth0]:3128' --no_proxy ''
  assert_success
  for key in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    [[ $(<"$manager_file") == *"DefaultEnvironment=\"$key=http://[fe80::1%%25eth0]:3128\""* &&
       $(<"${managed_files[2]}") == *"Environment=\"$key=http://[fe80::1%%25eth0]:3128\""* ]] ||
      fail "Literal percent was not escaped for $key."
  done
  for key in no_proxy NO_PROXY; do
    [[ $(<"$manager_file") == *"DefaultEnvironment=\"$key=\""* ]] || fail "Empty $key was not preserved."
  done
  [[ $(<"$unrelated_manager_file") == "$unrelated_manager_before" ]] || fail 'Unrelated defaults changed.'
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'Combined drop-in changes must reload only once.'
  pass 'systemd renderers preserve literal percent and empty bypass'
fi

if matches_filter 'generator warning remains visible without failing reload'; then
  seed_files
  fixture_reload_mode=warning
  run_script 0 --systemd-manager --waagent --apply --restartdaemons "${configuration_args[@]}"
  [[ $status == 0 && $errors == *'systemd-rc-local-generator:'* &&
     $output == *'Reloading systemd configuration; host generators may emit warnings.'* &&
     $output == *'systemd configuration reloaded.'* ]] || fail "Reload warning handling failed: $errors"
  assert_manager_configuration
  [[ $(<"$test_root/systemctl.log") == $'daemon-reload\nrestart waagent.service' ]] ||
    fail 'Successful reload must restart only the selected service.'
  pass 'generator warning remains visible without failing reload'
fi

if matches_filter 'failed reload remains fatal and stops restarts'; then
  seed_files
  fixture_reload_mode=failure
  run_script 0 --systemd-manager --waagent --apply --restartdaemons "${configuration_args[@]}"
  [[ $status != 0 && $errors == *'Fixture reload failed.'* && $errors == *'systemd reload failed'* &&
     $output != *'systemd configuration reloaded.'* ]] || fail 'Failed reload was hidden or reported as successful.'
  assert_manager_configuration
  [[ $(<"$test_root/systemctl.log") == 'daemon-reload' ]] || fail 'A service restarted after a failed reload.'
  pass 'failed reload remains fatal and stops restarts'
fi

((passed > 0)) || fail "No cases match '$filter'."
printf 'Passed %s target/removal cases using private files and mocked privileges/services.\n' "$passed"
