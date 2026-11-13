#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
(($# <= 1)) || fail 'Usage: test-validation.sh [case-name-pattern]'
filter=${1:-*}
script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/configure-proxy.sh"
diff_path=$(command -v diff) || fail 'diff is required.'
cat_path=$(command -v cat) || fail 'cat is required.'
test_root=$(mktemp -d)
readonly test_root
cleanup() {
  rm -f -- "$test_root/bin/bash" "$test_root/bin/cat" "$test_root/bin/diff" \
    "$test_root/bin/systemctl" "$test_root/stdout" "$test_root/stderr"
  rmdir -- "$test_root/bin" "$test_root"
}
trap cleanup EXIT
mkdir -- "$test_root/bin"
ln -s -- "$BASH" "$test_root/bin/bash"
ln -s -- "$cat_path" "$test_root/bin/cat"
ln -s -- "$diff_path" "$test_root/bin/diff"
cat > "$test_root/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ $# == 4 && $1 == show && $2 == configure-proxy-validation-*.service &&
      $3 == --property=LoadState && $4 == --value ]]; then
  printf 'loaded\n'
else
  printf 'Blocked unexpected systemctl command: %s\n' "$*" >&2
  exit 99
fi
STUB
chmod +x -- "$test_root/bin/systemctl"
if PATH="$test_root/bin" command -v python3 >/dev/null; then
  fail 'The fixture PATH must not provide Python.'
fi

unit="configure-proxy-validation-${test_root##*/}.service"
target_dir="/etc/systemd/system/$unit.d"
[[ ! -e $target_dir && ! -L $target_dir ]] || fail 'Fixture service path already exists.'
passed=0
default_proxy=http://proxy.example:8080

matches_filter() {
  # The optional case selector is intentionally a Bash glob.
  # shellcheck disable=SC2053
  [[ $1 == $filter ]]
}

run_script() {
  status=0
  PATH="$test_root/bin" "$BASH" "$script_path" --daemons "$unit" "$@" \
    > "$test_root/stdout" 2> "$test_root/stderr" || status=$?
  output=$(<"$test_root/stdout")
  errors=$(<"$test_root/stderr")
  [[ ! -e $target_dir && ! -L $target_dir ]] || fail 'Preview created service configuration.'
}

check_config() {
  local name=$1 expected_error=$2 http=$3 https=$4 bypass=$5 key
  matches_filter "$name" || return 0
  run_script --http_proxy "$http" --https_proxy "$https" --no_proxy "$bypass"
  if [[ -n $expected_error ]]; then
    [[ $status == 1 && $errors == *"ERROR: "*"$expected_error"* ]] ||
      fail "$name: expected a validation error containing '$expected_error', got status=$status: $errors"
    [[ $output != *'Preview only;'* ]] || fail "$name: invalid input reached target processing."
  else
    [[ $status == 0 && -z $errors ]] || fail "$name: status=$status: $errors"
    [[ $output == *'Preview only; no files or services will be changed.'* ]] ||
      fail "$name: expected a configuration preview."
    for key in http_proxy HTTP_PROXY; do
      [[ $output == *"+Environment=\"$key=${http//%/%%}\""* ]] || fail "$name: missing $key."
    done
    for key in https_proxy HTTPS_PROXY; do
      [[ $output == *"+Environment=\"$key=${https//%/%%}\""* ]] || fail "$name: missing $key."
    done
    for key in no_proxy NO_PROXY; do
      [[ $output == *"+Environment=\"$key=${bypass//%/%%}\""* ]] || fail "$name: missing $key."
    done
  fi
  passed=$((passed + 1))
  printf 'PASS %s\n' "$name"
}

while IFS='|' read -r name value; do
  check_config "$name" '' "$value" "$value" ''
done <<'CASES'
hostname proxy|http://proxy.example
case and trailing dot|HTTPS://Proxy.Example.:000443
IPv4 proxy|http://192.0.2.1:65535
IPv6 compressed proxy|http://[2001:db8::1]:8080
IPv6 full proxy|https://[2001:db8:0:1:2:3:4:5]
IPv6 mapped IPv4 proxy|http://[::ffff:192.0.2.1]:80
IPv6 scoped proxy|http://[fe80::1%25eth0]:3128
CASES

while IFS='|' read -r name value; do
  check_config "$name" http_proxy "$value" "$default_proxy" ''
done <<'CASES'
reject unsupported scheme|socks://proxy.example:1080
reject credentials|http://user:password@proxy.example
reject path|http://proxy.example/
reject query|http://proxy.example?x=1
reject fragment|http://proxy.example#section
reject invalid hostname|http://-proxy.example
reject numeric non-address|http://1234
reject IPv4 octet overflow|http://256.0.0.1
reject IPv4 leading zero|http://192.000.2.1
reject missing port|http://proxy.example:
reject zero port|http://proxy.example:0
reject large port|http://proxy.example:65536
reject arithmetic overflow|http://proxy.example:18446744073709551617
reject unbracketed IPv6 proxy|http://2001:db8::1
reject bracketed IPv4 proxy|http://[192.0.2.1]
reject IPv6 duplicate compression|http://[2001::db8::1]
reject IPv6 triple colon|http://[2001:db8:::]
reject IPv6 oversized group|http://[12345::1]
reject IPv6 too few groups|http://[1:2:3:4:5:6:7]
reject IPv6 zero-width compression|http://[1:2:3:4:5:6:7:8::]
reject invalid embedded IPv4|http://[::ffff:192.0.2.999]
CASES

while IFS='|' read -r name value; do
  check_config "$name" '' "$default_proxy" "$default_proxy" "$value"
done <<'CASES'
empty bypass|
wildcard bypass|*
mixed bypass|localhost,.example.local,example.local.,192.0.2.1,::1
bypass ports|localhost:080,192.0.2.1:65535,[::1]:443
IPv4 CIDR host bits|192.0.2.129/24
IPv4 CIDR boundaries|0.0.0.0/0,255.255.255.255/32,192.0.2.1/00024
IPv4 dotted masks|192.0.2.129/255.255.255.0,192.0.2.129/0.0.0.255
IPv6 CIDRs|::/0,2001:db8::1234/64,::1/128
IPv6 bypass forms|[::],::ffff:192.0.2.1,[::ffff:192.0.2.1]:443,fe80::1%eth0
CASES

while IFS='|' read -r name value; do
  check_config "$name" no_proxy "$default_proxy" "$default_proxy" "$value"
done <<'CASES'
reject empty bypass entry|localhost,,example.local
reject trailing comma|localhost,
reject bypass whitespace|localhost, example.local
reject mixed wildcard|*,localhost
reject IPv4 CIDR overflow|192.0.2.1/33
reject noncontiguous mask|192.0.2.1/255.0.255.0
reject IPv6 CIDR overflow|2001:db8::/129
reject CIDR arithmetic overflow|::/18446744073709551616
reject CIDR without prefix|192.0.2.1/
reject CIDR on hostname|example.local/24
reject duplicate CIDR|192.0.2.1/24/24
reject bypass port overflow|[::1]:65536
reject bracketed IPv4 bypass|[192.0.2.1]
reject malformed IPv6 bypass|[2001:db8:::1]
reject unsafe IPv6 scope|fe80::1%bad"scope
CASES

check_config 'validate HTTPS independently' https_proxy "$default_proxy" 'http://proxy.example:0' ''
check_config 'reject proxy control characters' http_proxy $'http://proxy.example\n' "$default_proxy" ''
check_config 'reject bypass control characters' no_proxy "$default_proxy" "$default_proxy" $'localhost\n'
check_config 'reject shell quoting in bypass' no_proxy "$default_proxy" "$default_proxy" "example.local'"
printf -v long_label '%064d' 0
check_config 'reject oversized DNS label' http_proxy "http://$long_label.example" "$default_proxy" ''

if matches_filter 'removal preview without Python'; then
  run_script --remove
  [[ $status == 0 && -z $errors && $output == *'Removal preview only;'* ]] ||
    fail "Removal preview failed: status=$status: $errors"
  passed=$((passed + 1))
  printf 'PASS removal preview without Python\n'
fi

((passed > 0)) || fail "No cases match '$filter'."
printf 'Passed %s validation cases without Python or live system changes.\n' "$passed"
