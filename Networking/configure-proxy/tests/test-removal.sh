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
directories=(
  "$test_root/etc/systemd/system/waagent.service.d"
  "$test_root/etc/systemd/system/other.service.d"
  "$test_root/etc/systemd/system" "$test_root/etc/systemd"
  "$test_root/etc/profile.d" "$test_root/etc/sudoers.d" "$test_root/etc"
  "$test_root/bin" "$test_root"
)
tools=(bash cat diff awk dirname install mktemp chmod mv rm)
cleanup() {
  local tool directory
  rm -f -- "$fixture_script" "$environment_file" "${managed_files[@]}" "${custom_files[@]}" "$extra_file" \
    "$test_root/stdout" "$test_root/stderr" "$test_root/systemctl.log" \
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
  'show other.service --property=LoadState --value') state=$FIXTURE_OTHER_STATE ;;
  'daemon-reload'|'restart waagent.service'|'restart other.service')
    printf '%s\n' "$*" >> "$FIXTURE_ROOT/systemctl.log"; exit 0 ;;
  *) printf 'Blocked unexpected systemctl command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ $state == error ]]; then
  printf 'Fixture service manager is unavailable.\n' >&2
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
passed=0

matches_filter() {
  # The optional case selector is intentionally a Bash glob.
  # shellcheck disable=SC2053
  [[ $1 == $filter ]]
}

seed_files() {
  local file
  fixture_waagent_state=loaded
  fixture_other_state=loaded
  rm -f -- "$environment_file" "${managed_files[@]}" "${custom_files[@]}" "$extra_file"
  printf '%s\n' "$environment_before" > "$environment_file"
  for file in "${managed_files[@]}"; do printf '%s\n' "$managed_before" > "$file"; done
}

run_script() {
  local uid=$1
  shift
  : > "$test_root/systemctl.log"
  status=0
  FIXTURE_EUID="$uid" FIXTURE_ROOT="$test_root" \
    FIXTURE_WAAGENT_STATE="$fixture_waagent_state" FIXTURE_OTHER_STATE="$fixture_other_state" PATH="$test_root/bin" \
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

((passed > 0)) || fail "No cases match '$filter'."
printf 'Passed %s target/removal cases using private files and mocked privileges/services.\n' "$passed"
