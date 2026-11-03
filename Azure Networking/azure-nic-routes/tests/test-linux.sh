#!/usr/bin/env bash
# Fixture subshells intentionally discard variable changes; parent-state assertions verify isolation.
# shellcheck disable=SC2031
set -Eeuo pipefail
script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/linux/azure-nic-routes.sh"
# Resolve the runtime-computed implementation path for static analysis.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../linux/azure-nic-routes.sh
source "$script_path"
fixture_native_networkd_configuration=$(declare -f simple_networkd_configuration)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p -- "$test_root/profiles"
fixture_addresses=$'7: test22 inet 172.16.0.132/28 scope global test22\n3: test100 inet 192.168.1.4/23 scope global test100\n9: test180 inet 10.0.1.5/24 scope global test180'
fixture_routes=$'default via 10.0.1.1 dev test180 proto 16\n172.16.0.128/28 dev test22 proto 2 scope 253 src 172.16.0.132\n192.168.0.0/23 dev test100 proto 2 scope 253 src 192.168.1.4\n10.0.1.0/24 dev test180 proto 2 scope 253 src 10.0.1.5'
fixture_rules=$'0: from all lookup local\n32766: from all lookup main\n32767: from all lookup default'
printf '%s\n' "$fixture_routes" > "$test_root/network"
: > "$test_root/nm-mutations"

fixture_profile_uuid() {
    case $1 in
        test22) printf '22222222-2222-2222-2222-222222222222\n' ;;
        test100) printf '10000000-1000-1000-1000-100000000000\n' ;;
        test180) printf '18000000-1800-1800-1800-180000000000\n' ;;
        *) fail "Unknown fixture device: $1" ;;
    esac
}
for fixture_device in test22 test100 test180; do : > "$test_root/profiles/$(fixture_profile_uuid "$fixture_device")"; done

ip() {
    local line device protocol metric gateway source existing_metric
    case "$*" in
        '-N '*) printf '%s\n' 'Option "-N" is unknown, try "ip -help".' >&2; return 1 ;;
        '-o -4 address show scope global')
            printf '%s\n' "$fixture_addresses"
            if [[ ${fixture_late_cloud_address:-false} == true ]]; then
                [[ ! -f $test_root/address-read ]] || printf '11: extra inet 192.0.2.10/24 scope global extra\n'
                : > "$test_root/address-read"
            fi ;;
        '-4 -o route show table main')
            [[ ${fixture_main_route_failure:-false} != true ]] || return 1
            cat "$test_root/network" ;;
        '-4 -o route show table all')
            [[ ${fixture_cloud_route_failure:-false} != true ]] || return 1
            cat "$test_root/network"; printf '%s\n' "${fixture_cloud_routes:-}"
            if [[ ${fixture_late_cloud_route:-false} == true ]]; then
                [[ ! -f $test_root/policy-route-read ]] || printf '172.16.0.0/12 via 172.30.143.129 dev test22 table 30401 proto 4 metric 10\n'
                : > "$test_root/policy-route-read"
            fi ;;
        '-4 -o route show table main default')
            grep '^default ' "$test_root/network" || true
            [[ ${fixture_default_route_failure:-false} != true ]] ;;
        '-4 -o route show table main exact '*)
            while IFS= read -r line; do [[ ${line%% *} != "${!#}" ]] || printf '%s\n' "$line"; done < "$test_root/network" ;;
        '-4 -o rule show')
            if [[ ${fixture_late_cloud_rule:-false} == true ]]; then
                if [[ -f $test_root/policy-rule-read ]]; then printf '%s\n' "${fixture_rules//proto static/proto 4}"
                else printf '%s\n' "$fixture_rules"; fi
                : > "$test_root/policy-rule-read"
            else printf '%s\n' "$fixture_rules"; fi ;;
        '-4 route get '*) printf '%s\n' '172.16.1.4 from 172.16.0.132 via 172.16.0.129 dev test22' ;;
        '-4 route add '*' proto static metric '*)
            [[ ${fixture_add_failure:-} != "$4" ]] || return 1
            printf '%s via %s dev %s proto %s src %s metric %s\n' "$4" "$6" "$8" "${fixture_route_protocol:-4}" "${10}" "${14}" >> "$test_root/network" ;;
        '-4 route del '*' table main proto '*)
            if [[ ${fixture_require_saved_first:-false} == true ]]; then
                for existing_overlay in "$netplan_fixture_root/etc/netplan/"90-multinic-*.yaml; do [[ ! -e $existing_overlay ]] || fail 'Live route removal happened before saved overlay cleanup.'; done
            fi
            [[ ${fixture_delete_failure:-} != "$4" ]] || return 1
            device=$(simple_field "$*" dev); protocol=$(simple_field "$*" proto); metric=$(simple_field "$*" metric)
            gateway=$(simple_field "$*" via); source=$(simple_field "$*" src)
            : > "$test_root/network.new"
            while IFS= read -r line; do
                existing_metric=$(simple_field "$line" metric)
                if [[ ${line%% *} == "$4" && $(simple_field "$line" dev) == "$device" && $(simple_field "$line" proto) == "$protocol" && ${existing_metric:-0} == "$metric" && $(simple_field "$line" via) == "$gateway" && $(simple_field "$line" src) == "$source" ]]; then continue; fi
                printf '%s\n' "$line" >> "$test_root/network.new"
            done < "$test_root/network"
            mv -- "$test_root/network.new" "$test_root/network" ;;
        *) fail "Blocked unexpected ip command: $*" ;;
    esac
}
nmcli() {
    local device=${!#} uuid filename spec line separator='' reads=0
    case "$*" in
        '--escape no -g IP4.GATEWAY device show '*) ;;
        '--escape no -g DHCP4.OPTION device show '*) [[ $device != test22 ]] || printf '%s\n' "${fixture_dhcp:-requested_routers = 1}" ;;
        '--escape no -g GENERAL.CON-UUID device show '*) [[ ${fixture_no_nm_owner:-false} == true ]] || fixture_profile_uuid "$device" ;;
        '--terse --escape no -f UUID,FILENAME connection show')
            [[ ${fixture_profile_storage_failure:-false} != true ]] || return 1
            for device in test22 test100 test180; do
                [[ $device != test22 || ${fixture_profile_match_mode:-} != missing ]] || continue
                uuid=$(fixture_profile_uuid "$device")
                filename="${fixture_profile_directory:-/etc/NetworkManager/system-connections}/$device.nmconnection"
                if [[ $device == test22 && ${fixture_profile_storage_path+x} ]]; then filename=$fixture_profile_storage_path; fi
                printf '%s:%s\n' "$uuid" "$filename"
                if [[ $device == test22 && ${fixture_profile_match_mode:-} == duplicate ]]; then printf '%s:/etc/NetworkManager/system-connections/duplicate.nmconnection\n' "$uuid"; fi
            done ;;
        '--escape no -g connection.autoconnect connection show uuid '*) printf '%s\n' "${fixture_autoconnect:-yes}" ;;
        '--escape no -g connection.permissions connection show uuid '*) printf '%s\n' "${fixture_permissions:-}" ;;
        '--escape no -g ipv4.method connection show uuid '*)
            [[ ${fixture_method_failure:-false} != true ]] || return 1
            printf '%s\n' "${fixture_ipv4_method:-auto}" ;;
        '--escape no -g ipv4.route-table connection show uuid '*) printf '%s\n' "${fixture_route_table:-0}" ;;
        '--escape no -g ipv4.routing-rules connection show uuid '*)
            [[ ${fixture_saved_policy_failure:-false} != true ]] || return 1
            printf '%s\n' "${fixture_saved_policy:-}"
            if [[ ${fixture_late_saved_policy:-false} == true ]]; then
                [[ ! -f $test_root/saved-policy-read ]] || printf 'priority 100 from all table 100\n'
                : > "$test_root/saved-policy-read"
            fi ;;
        '--escape no -g ipv4.routes connection show uuid '*)
            if [[ -n ${fixture_saved_read_limit:-} ]]; then
                [[ ! -f $test_root/profile-reads ]] || read -r reads < "$test_root/profile-reads"
                printf '%s\n' "$((reads+1))" > "$test_root/profile-reads"
                ((reads < fixture_saved_read_limit)) || return 1
            fi
            while IFS= read -r line; do printf '%s%s' "$separator" "$line"; separator=', '; done < "$test_root/profiles/$device"
            printf '\n' ;;
        '--terse --escape no -f DEVICE,TYPE,STATE device status')
            printf '%s\n' 'test22:ethernet:connected' 'test100:ethernet:connected' 'test180:ethernet:connected' 'ignored_vf:ethernet:unmanaged' 'offline:ethernet:disconnected' 'lo:loopback:connected' ;;
        'connection modify uuid '*)
            uuid=$4; spec=$6
            [[ ${fixture_modify_failure:-} != "$uuid" ]] || return 1
            if [[ $5 == +ipv4.routes ]]; then printf '%s\n' "$spec" >> "$test_root/profiles/$uuid"
            elif [[ $5 == -ipv4.routes ]]; then
                : > "$test_root/profiles/$uuid.new"
                while IFS= read -r line; do [[ $line == "$spec" ]] || printf '%s\n' "$line" >> "$test_root/profiles/$uuid.new"; done < "$test_root/profiles/$uuid"
                mv -- "$test_root/profiles/$uuid.new" "$test_root/profiles/$uuid"
            else fail 'Blocked non-route profile change.'; fi
            printf '%s\n' "$*" >> "$test_root/nm-mutations" ;;
        *) fail "Blocked unexpected nmcli command: $*" ;;
    esac
    return 0
}
simple_root() { :; }
simple_networkd_configuration() { :; }
passed=0
expect() {
    local expected=$1 name=$2 status=0
    shift 2
    ( "$@" ) > "$test_root/output" 2>&1 || status=$?
    if [[ ( $expected == pass && $status != 0 ) || ( $expected == fail && $status == 0 ) ]]; then cat "$test_root/output" >&2; fail "Unexpected result: $name (exit $status)"; fi
    printf 'PASS %s\n' "$name"; passed=$((passed+1))
}

printf '%s\n' 'ID="rocky"' 'ID_LIKE="rhel centos fedora"' > "$test_root/os-release"
expect pass 'quoted OS metadata' simple_os_release "$test_root/os-release"
expect fail 'missing OS metadata' simple_os_release "$test_root/missing"
printf '%s\n' 'ID_LIKE="rhel"' > "$test_root/os-release"
expect fail 'missing OS ID' simple_os_release "$test_root/os-release"
printf '%s\n' 'ID=debian' 'VERSION_ID=13' > "$test_root/os-release"
expect pass 'Debian OS metadata does not require ID_LIKE' simple_os_release "$test_root/os-release"
[[ $(cat "$test_root/output") == $'debian\n\n13' ]] || fail 'OS reader lost the empty ID_LIKE field or included diagnostic text.'
printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID=26.04' > "$test_root/os-release"
expect pass 'Ubuntu OS metadata preserves its Debian family' simple_os_release "$test_root/os-release"
[[ $(cat "$test_root/output") == $'ubuntu\ndebian\n26.04' ]] || fail 'OS reader changed its structured output.'
simple_os_release() { printf '%s\n' "${fixture_os_id-rocky}" "${fixture_os_like-rhel fedora}" "${fixture_os_version:-}"; }
fixture_os_id=debian; fixture_os_like=''; fixture_os_version=13
expect pass 'Debian diagnostics explicitly show an absent ID_LIKE' simple_check_os
grep -Fxq 'OS: ID=debian VERSION_ID=13 ID_LIKE=(not set)' "$test_root/output" || fail 'Missing Debian OS diagnostic.'
fixture_os_id=ubuntu; fixture_os_like=debian; fixture_os_version=26.04
expect pass 'Ubuntu diagnostics show its ID_LIKE without selecting a backend by distro' simple_check_os
grep -Fxq 'OS: ID=ubuntu VERSION_ID=26.04 ID_LIKE=debian' "$test_root/output" || fail 'Missing Ubuntu OS diagnostic.'
unset fixture_os_id fixture_os_like fixture_os_version
for fixture_os_id in rhel rocky centos fedora almalinux ol; do fixture_os_like=''; expect pass "accepted OS $fixture_os_id" simple_check_os; done
for fixture_os_id in ubuntu debian alpine unknown; do fixture_os_like=linux; expect pass "OS metadata alone does not reject $fixture_os_id" simple_check_os; done
fixture_os_id=custom; fixture_os_like='linux fedora'
expect pass 'OS family is diagnostic metadata' simple_check_os
fixture_os_like='rhel_clone fedora-like'
expect pass 'unrecognized OS family does not gate backend discovery' simple_check_os
fixture_os_like='*'; printf 'fixture\n' > "$test_root/fedora"
pushd -- "$test_root" >/dev/null
expect pass 'OS wildcard is not expanded' simple_check_os
grep -Fxq 'OS: ID=custom VERSION_ID=(not set) ID_LIKE=*' "$test_root/output" || fail 'OS family metadata was expanded or interpreted.'
popd >/dev/null
fixture_os_id=ubuntu; fixture_os_like=debian
expect pass 'help bypasses OS metadata discovery' simple_main --help
if grep -Eq '^(OS:|MODE:|BACKEND )' "$test_root/output"; then fail 'Help unexpectedly performed diagnostic discovery.'; fi
for fixture_os_case in debian:12 debian:14 ubuntu:24.04 ubuntu:28.04 rhel:8 rhel:9 custom:99; do
    IFS=: read -r fixture_os_id fixture_os_version <<< "$fixture_os_case"
    fixture_os_like=''
    expect pass "$fixture_os_id $fixture_os_version uses its supported NetworkManager backend" simple_main --persist --map 172.16.0.132/32=172.16.0.0/16
    grep -Fxq 'BACKEND test22: NetworkManager; tool=nmcli' "$test_root/output" || fail 'OS metadata changed NetworkManager backend selection.'
    [[ $(cat "$test_root/network") == "$fixture_routes" && ! -s $test_root/nm-mutations ]] || fail 'Version-independent preview changed networking.'
done
fixture_no_nm_owner=true
expect fail 'OS admission without a supported interface owner blocks preview' simple_main --map 172.16.0.132/32=172.16.0.0/16
grep -Fq 'Mapped interface has no supported authoritative networking owner.' "$test_root/output" || fail 'Preview did not refuse unsupported backend ownership.'
expect fail 'OS admission without a supported interface owner blocks apply' simple_main --apply --map 172.16.0.132/32=172.16.0.0/16
grep -Fq 'Mapped interface has no supported authoritative networking owner.' "$test_root/output" || fail 'Apply did not refuse unsupported backend ownership.'
[[ $(cat "$test_root/network") == "$fixture_routes" && ! -s $test_root/nm-mutations ]] || fail 'Unsupported backend changed networking.'
unset fixture_os_id fixture_os_like fixture_os_version fixture_no_nm_owner

# The function restored by eval invokes these scoped networking mocks.
# shellcheck disable=SC2317
networkd_dbus_fixture() (
    eval "$fixture_native_networkd_configuration"
    local index
    read -r index < /sys/class/net/lo/ifindex
    systemctl() { [[ $* == 'is-active --quiet systemd-networkd' ]] || fail "Unexpected systemctl command: $*"; }
    busctl() {
        case $* in
            '--system --auto-start=no call org.freedesktop.network1 /org/freedesktop/network1 org.freedesktop.network1.Manager GetLinkByName s lo')
                [[ ${fixture_bus_lookup_failure:-false} != true ]] || return 1
                printf '%s\n' "${fixture_bus_reply:-io $index \"/org/freedesktop/network1/link/_31\"}" ;;
            '--system --auto-start=no get-property org.freedesktop.network1 /org/freedesktop/network1/link/_31 org.freedesktop.network1.Link AdministrativeState')
                [[ ${fixture_bus_property_failure:-false} != true ]] || return 1
                printf 's "%s"\n' "${fixture_bus_state:-configured}" ;;
            *) fail "Blocked unexpected busctl command: $*" ;;
        esac
    }
    networkctl() {
        [[ $* == '--no-pager cat @lo' ]] || fail "Blocked unexpected networkctl command: $*"
        printf '# /run/systemd/network/10-netplan-fixture.network\n[Network]\nDHCP=ipv4\n'
    }
    simple_networkd_configuration lo
)
expect pass 'networkd uses the manager-returned escaped D-Bus object path' networkd_dbus_fixture
grep -Fq '# /run/systemd/network/10-netplan-fixture.network' "$test_root/output" || fail 'Configured networkd ownership was not inspected.'
fixture_bus_state=unmanaged
expect pass 'resolved unmanaged networkd links do not claim ownership' networkd_dbus_fixture
[[ ! -s $test_root/output ]] || fail 'Unmanaged networkd link returned configuration.'
fixture_bus_state=configuring
expect fail 'resolved but unstable networkd links remain fail-closed' networkd_dbus_fixture
unset fixture_bus_state
fixture_bus_lookup_failure=true
expect fail 'networkd object lookup errors remain fail-closed' networkd_dbus_fixture
unset fixture_bus_lookup_failure
fixture_bus_property_failure=true
expect fail 'networkd property lookup errors remain fail-closed' networkd_dbus_fixture
unset fixture_bus_property_failure
for fixture_bus_reply in 'io 999999 "/org/freedesktop/network1/link/_31"' 's "/org/freedesktop/network1/link/_31"' 'io 1 "/unexpected/path"' $'io 1 "/org/freedesktop/network1/link/_31"\nextra'; do
    expect fail 'networkd rejects malformed or changed manager identities' networkd_dbus_fixture
done
unset fixture_bus_reply

# Native dispatch resolves these mock command names at runtime.
# shellcheck disable=SC2317
netplan_native_dispatch_fixture() (
    simple_netplan_executable() {
        [[ ${fixture_native_missing:-false} != true ]] || return 1
        [[ $1 != configure || ${fixture_native_legacy:-false} != true ]] || return 1
        printf 'fixture_native_%s\n' "$1"
    }
    fixture_native_configure() {
        [[ ${SYSTEMD_OFFLINE:-} == 1 && $* == '--root-dir /fixture' ]] || fail 'Unexpected native configure invocation.'
        [[ ${fixture_native_configure_failure:-false} != true ]] || return 17
        printf 'native-configure\n'
    }
    fixture_native_generate() {
        [[ ${SYSTEMD_OFFLINE:-} == 1 ]] || fail 'Native invocation lost offline mode.'
        case $* in
            '--root-dir /fixture --mapping eth0'|'--root-dir /fixture --mapping=eth0') printf 'native-mapping\n' ;;
            '--root-dir /fixture')
                [[ ${fixture_native_legacy:-false} == true ]] || fail 'A systemd-only generator must not compile renderer configuration.'
                printf 'legacy-generate\n' ;;
            *) fail 'Unexpected native generator invocation.' ;;
        esac
    }
    simple_netplan_generator "$@"
)
expect pass 'split Netplan installation uses native configure for sandbox compilation' netplan_native_dispatch_fixture --root-dir /fixture
[[ $(cat "$test_root/output") == native-configure ]] || fail 'Renderer compilation used the wrong native executable.'
expect pass 'split Netplan installation keeps native generate for mapping' netplan_native_dispatch_fixture --root-dir /fixture --mapping eth0
[[ $(cat "$test_root/output") == native-mapping ]] || fail 'Mapping did not use the legacy mapping API.'
expect pass 'native mapping dispatch supports the equals option form' netplan_native_dispatch_fixture --root-dir /fixture --mapping=eth0
fixture_native_legacy=true
expect pass 'older Netplan keeps its native generator compilation path' netplan_native_dispatch_fixture --root-dir /fixture
[[ $(cat "$test_root/output") == legacy-generate ]] || fail 'Older native Netplan compatibility was lost.'
unset fixture_native_legacy
fixture_native_configure_failure=true
expect fail 'native configure failures never fall back to the systemd-only generator' netplan_native_dispatch_fixture --root-dir /fixture
unset fixture_native_configure_failure
fixture_native_missing=true
expect fail 'missing native Netplan executables fail without installing packages' netplan_native_dispatch_fixture --root-dir /fixture
unset fixture_native_missing

common=(--map 172.16.0.0/16=172.16.0.0/16 --map 192.168.0.0/16=192.168.0.0/16 --map "10.0.0.0/8=10.0.0.0/8,172.20.0.0/16")
host_maps=(--map 172.16.0.132/32=172.16.0.0/16 --map 192.168.1.4/32=192.168.0.0/16 --map "10.0.1.5/32=10.0.0.0/8,172.20.0.0/16")
expect pass 'mixed prefixes and reordered NICs preview' simple_main "${common[@]}"
grep -Fxq 'OS: ID=rocky VERSION_ID=(not set) ID_LIKE=rhel fedora' "$test_root/output" || fail 'Missing RHEL-family OS diagnostic.'
grep -Fxq 'MODE: preview; operation=routes; persistence=no; runtime routes use ip' "$test_root/output" || fail 'Wrong runtime preview diagnostic.'
grep -Fxq 'BACKEND test22: NetworkManager; tool=nmcli' "$test_root/output" || fail 'Missing verified NetworkManager backend diagnostic.'
grep -q 'gateway=172.16.0.129' "$test_root/output" || fail 'Wrong /28 gateway.'
grep -q 'gateway=192.168.0.1' "$test_root/output" || fail 'Wrong /23 gateway.'
expect pass 'exact /32 selectors retain actual NIC prefixes and gateways' simple_main --persist "${host_maps[@]}"
grep -Fxq 'MODE: preview; operation=routes; persistence=yes; runtime routes use ip' "$test_root/output" || fail 'Persistent preview diagnostic implies mutation or lost persistence intent.'
grep -Fq 'MAP 172.16.0.0/16 -> test22 source=172.16.0.132/28 gateway=172.16.0.129 ' "$test_root/output" || fail '/32 selector replaced the actual /28 prefix.'
grep -Fq 'MAP 192.168.0.0/16 -> test100 source=192.168.1.4/23 gateway=192.168.0.1 ' "$test_root/output" || fail '/32 selector replaced the actual /23 prefix.'
expect pass '/32 gateway override still validates against the actual subnet' simple_main --map 172.16.0.132/32=172.16.0.0/16 --gateway 172.16.0.132/32=172.16.0.142
grep -q 'gateway=172.16.0.142 evidence=override' "$test_root/output" || fail '/32 gateway override was not applied.'
for selector in 172.16.0.133/32 172.16.0.132/30; do
    expect pass "unassigned host or narrower non-host selector is skipped: $selector" simple_main --map "$selector=172.16.0.0/16"
    grep -q '^WARNING: No actual NIC subnet matches ' "$test_root/output" || fail 'Unmatched selector lost its warning.'
    if grep -q '^MAP ' "$test_root/output"; then fail 'Selector matched an unassigned host or only part of a NIC subnet.'; fi
done
expect fail 'overlapping subnet and exact-host selectors remain rejected' simple_main "${common[@]}" --map 172.16.0.132/32=172.24.0.0/16
fixture_addresses+=$'\n11: duplicate inet 172.16.0.132/28 scope global duplicate'
expect fail 'duplicate exact local addresses remain ambiguous for /32' simple_main --map 172.16.0.132/32=172.16.0.0/16
fixture_addresses=${fixture_addresses%$'\n11:'*}
[[ $(cat "$test_root/network") == "$fixture_routes" && ! -s $test_root/nm-mutations ]] || fail 'Preview mutation.'
expect pass 'missing NIC map warns while others remain planned' simple_main "${common[@]}" --map 172.24.0.0/16=172.24.0.0/16
grep -q '^WARNING: No actual NIC subnet matches ' "$test_root/output" || fail 'Missing warning.'
expect pass 'all unmatched maps are a no-op' simple_main --apply --map 172.24.0.0/16=172.24.0.0/16
expect fail 'unmatched destination is still validated' simple_main --apply "${common[@]}" --map 172.24.0.0/16=172.24.0.1/16
expect fail 'host bits rejected' simple_main --map 172.16.0.4/16=172.16.0.0/16
expect fail 'default route rejected' simple_main --map 172.16.0.0/16=0.0.0.0/0
expect fail 'invalid prefix rejected' simple_main --map 172.16.0.0/33=172.16.0.0/16
expect fail 'empty map destination rejected' simple_main --map 172.16.0.0/16=172.16.0.0/16,
expect fail 'overlapping selectors rejected' simple_main "${common[@]}" --map 172.16.0.0/24=172.24.0.0/16
expect fail 'duplicate destinations rejected' simple_main --map 172.16.0.0/16=172.24.0.0/16 --map 192.168.0.0/16=172.24.0.0/16
fixture_addresses+=$'\n11: other inet 172.16.0.133/28 scope global other'
expect fail 'multiple eligible addresses rejected' simple_main "${common[@]}"
fixture_addresses=${fixture_addresses%$'\n11:'*}
expect pass 'exact connected route stays direct' simple_main --apply --map 172.16.0.0/16=172.16.0.128/28
expect pass 'gateway override' simple_main "${common[@]}" --gateway 172.16.0.0/16=172.16.0.142
expect fail 'off-subnet gateway rejected' simple_main "${common[@]}" --gateway 172.16.0.0/16=172.16.1.1
expect fail 'local gateway rejected' simple_main "${common[@]}" --gateway 172.16.0.0/16=172.16.0.132
expect fail 'broadcast gateway rejected' simple_main "${common[@]}" --gateway 172.16.0.0/16=172.16.0.143
fixture_dhcp='requested_routers = 1 | routers = 172.16.0.142'
expect pass 'packed DHCP evidence precedes calculation' simple_main "${common[@]}"
grep -q 'gateway=172.16.0.142 evidence=DHCP' "$test_root/output" || fail 'DHCP evidence lost.'
fixture_dhcp=$'routers = 172.16.0.142\nrouters = 172.16.0.141'
expect fail 'conflicting gateways rejected' simple_main --apply "${common[@]}"
expect pass 'explicit gateway precedes conflicting evidence' simple_main "${common[@]}" --gateway 172.16.0.0/16=172.16.0.142
unset fixture_dhcp
fixture_rules+=$'\n100: from all lookup 100'
expect fail 'custom policy rules require review' simple_main --apply "${common[@]}"
grep -Fq 'Offending rule: 100: from all lookup 100' "$test_root/output" || fail 'Custom table rejection did not identify the rule.'
fixture_rules=${fixture_rules%$'\n100:'*}
fixture_rules+=$'\n100: from 172.16.0.132 lookup 100'
expect fail 'source policy rejection identifies the exact rule without bypassing review' simple_main --apply "${common[@]}"
grep -Fq 'Offending rule: 100: from 172.16.0.132 lookup 100' "$test_root/output" || fail 'Source policy rejection did not identify the rule.'
fixture_rules=${fixture_rules%$'\n100:'*}
legacy_iproute_fixture() (
    local test_root fixture_device action=$1 baseline applied mutations defaults
    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir -p -- "$test_root/profiles"
    : > "$test_root/nm-mutations"
    for fixture_device in test22 test100 test180; do : > "$test_root/profiles/$(fixture_profile_uuid "$fixture_device")"; done
    simple_os_release() { printf '%s\n' rhel fedora 8.1; }
    fixture_route_protocol=static
    fixture_routes=${fixture_routes//proto 16/proto dhcp}
    fixture_routes=${fixture_routes//proto 2/proto kernel}
    fixture_routes=${fixture_routes//scope 253/scope link}
    printf '%s\n' "$fixture_routes" > "$test_root/network"
    baseline=$fixture_routes
    defaults=$(grep '^default ' "$test_root/network")
    if ip -N -4 -o route show table main > "$test_root/unsupported" 2>&1; then fail 'Legacy fixture unexpectedly accepts -N.'; fi
    grep -Fq 'Option "-N" is unknown' "$test_root/unsupported" || fail 'Legacy fixture did not reproduce the reported option failure.'
    if [[ $action == main-read-failure ]]; then
        fixture_main_route_failure=true
        if simple_main "${common[@]}"; then fail 'Failed main-table discovery was admitted in preview.'; fi
        if simple_main --apply "${common[@]}"; then fail 'Failed main-table discovery was admitted in apply.'; fi
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/nm-mutations ]] || fail 'Failed legacy discovery changed networking.'
        return
    fi
    if [[ $action == default-read-failure ]]; then
        fixture_default_route_failure=true
        if simple_main --apply "${common[@]}" > "$test_root/default-output" 2>&1; then fail 'Failed default verification with valid partial output was accepted.'; fi
        grep -Fq 'Cannot verify default routes.' "$test_root/default-output" || fail 'Default read failure lost its specific diagnostic.'
        [[ $(grep '^default ' "$test_root/network") == "$defaults" && ! -s $test_root/nm-mutations ]] || fail 'Failed default verification changed the primary default or saved settings.'
        return
    fi
    simple_main "${common[@]}"
    [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/nm-mutations ]] || fail 'Legacy preview changed networking.'
    simple_main --apply "${common[@]}"
    applied=$(cat "$test_root/network")
    [[ $(grep -c 'proto static .*metric 42762' "$test_root/network") == 4 && ! -s $test_root/nm-mutations ]] || fail 'Legacy runtime routes were not verified or unexpectedly saved.'
    simple_main --apply "${common[@]}"
    [[ $(cat "$test_root/network") == "$applied" && ! -s $test_root/nm-mutations ]] || fail 'Legacy runtime apply is not idempotent.'
    simple_main --rollback --apply
    [[ $(cat "$test_root/network") == "$baseline" ]] || fail 'Legacy runtime rollback changed defaults or connected routes.'
    simple_main --apply --persist "${common[@]}"
    applied=$(cat "$test_root/network"); mutations=$(cat "$test_root/nm-mutations")
    simple_main --apply --persist "${common[@]}"
    [[ $(cat "$test_root/network") == "$applied" && $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Legacy persistent apply is not idempotent.'
    printf '%s\n' '172.24.0.0/16 via 10.0.1.1 dev test180 proto boot metric 123' >> "$test_root/network"
    simple_main --reset --apply
    [[ $(cat "$test_root/network") == "$baseline" ]] || fail 'Legacy reset failed to remove static/boot routes or changed the baseline.'
    for fixture_device in test22 test100 test180; do [[ ! -s $test_root/profiles/$(fixture_profile_uuid "$fixture_device") ]] || fail 'Legacy reset retained a saved route.'; done
)
expect pass 'legacy iproute2 named output supports preview apply repeat persistence rollback and reset' legacy_iproute_fixture workflow
expect pass 'legacy main-table read failures remain fatal before any writes' legacy_iproute_fixture main-read-failure
expect pass 'failed default verification is fatal even when stdout contains the unchanged default' legacy_iproute_fixture default-read-failure
# This fixture must not change its caller's temporary root or route baseline.
# shellcheck disable=SC2030
cloud_policy_fixture() (
    local test_root fixture_device action=${1:-preview} baseline rules_snapshot tables_snapshot applied mutations
    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir -p -- "$test_root/profiles"
    : > "$test_root/nm-mutations"
    for fixture_device in test22 test100 test180; do : > "$test_root/profiles/$(fixture_profile_uuid "$fixture_device")"; done
    fixture_addresses=$'3: test22 inet 172.30.143.132/25 scope global test22\n2: test180 inet 10.83.86.118/28 scope global test180'
    fixture_rules=$'0: from all lookup local\n30200: from 10.83.86.118 lookup 30200 proto static\n30201: from 172.30.143.132 lookup 30201 proto static\n30350: from all lookup main suppress_prefixlength 0 proto static\n30400: from 10.83.86.118 lookup 30400 proto static\n30401: from 172.30.143.132 lookup 30401 proto static\n32766: from all lookup main\n32767: from all lookup default'
    fixture_cloud_routes=$'default via 10.83.86.113 dev test180 table 30400 proto 4 metric 10\ndefault via 172.30.143.129 dev test22 table 30401 proto 4 metric 10\n10.83.86.112/28 dev test180 table 30200 proto 4 scope 253 metric 10\n172.30.143.128/25 dev test22 table 30201 proto 4 scope 253 metric 10'
    fixture_routes=$'default via 10.83.86.113 dev test180 proto 16 src 10.83.86.118 metric 100\n172.30.143.128/25 dev test22 proto 2 scope 253 src 172.30.143.132 metric 101\n10.83.86.112/28 dev test180 proto 2 scope 253 src 10.83.86.118 metric 100\n168.63.129.16 via 10.83.86.113 dev test180 proto 16 src 10.83.86.118 metric 100\n169.254.169.254 via 10.83.86.113 dev test180 proto 16 src 10.83.86.118 metric 100'
    case $action in
        named-routes)
            fixture_cloud_routes=${fixture_cloud_routes//proto 4/proto static}
            fixture_cloud_routes=${fixture_cloud_routes//scope 253/scope link}
            fixture_cloud_routes+=$'\nlocal 172.30.143.132 dev test22 table local proto kernel scope host src 172.30.143.132\n172.30.143.128/25 dev test22 table main proto kernel scope link src 172.30.143.132 metric 101'
            fixture_routes=${fixture_routes//proto 16/proto dhcp}; fixture_routes=${fixture_routes//proto 2/proto kernel}; fixture_routes=${fixture_routes//scope 253/scope link}
            fixture_route_protocol=static ;;
        unknown-protocol) fixture_cloud_routes=${fixture_cloud_routes/proto 4/proto custom} ;;
        wrong-scope) fixture_cloud_routes=${fixture_cloud_routes/scope 253/scope host} ;;
        named-auxiliary-table) fixture_cloud_routes=${fixture_cloud_routes/table 30400/table custom} ;;
        extra-rule) fixture_rules+=$'\n100: from all lookup 100' ;;
        missing-suppress) fixture_rules=${fixture_rules/$'\n30350: from all lookup main suppress_prefixlength 0 proto static'/} ;;
        wrong-suppress) fixture_rules=${fixture_rules/suppress_prefixlength 0/suppress_prefixlength 1} ;;
        missing-pair) fixture_rules=${fixture_rules/$'\n30401: from 172.30.143.132 lookup 30401 proto static'/} ;;
        unknown-source) fixture_rules=${fixture_rules//172.30.143.132/172.30.143.133} ;;
        subnet-source) fixture_rules=${fixture_rules/from 172.30.143.132 lookup/from 172.30.143.0\/24 lookup} ;;
        extra-selector) fixture_rules=${fixture_rules/from 172.30.143.132 lookup/from 172.30.143.132 iif test22 lookup} ;;
        missing-route) fixture_cloud_routes=${fixture_cloud_routes%$'\n172.30.143.128/25'*} ;;
        wrong-subnet) fixture_cloud_routes=${fixture_cloud_routes/172.30.143.128\/25/172.30.143.0\/24} ;;
        wrong-gateway) fixture_cloud_routes=${fixture_cloud_routes/172.30.143.129/172.30.143.130} ;;
        wrong-device) fixture_cloud_routes=${fixture_cloud_routes/dev test22 table 30201/dev test180 table 30201} ;;
        wrong-metric) fixture_cloud_routes=${fixture_cloud_routes/metric 10/metric 42762} ;;
        shared-table)
            fixture_rules=${fixture_rules//30201/30200}; fixture_rules=${fixture_rules//30401/30400}
            fixture_cloud_routes=${fixture_cloud_routes//30201/30200}; fixture_cloud_routes=${fixture_cloud_routes//30401/30400} ;;
        out-of-range-index)
            fixture_rules=${fixture_rules//30201/30300}; fixture_rules=${fixture_rules//30401/30500}
            fixture_cloud_routes=${fixture_cloud_routes//30201/30300}; fixture_cloud_routes=${fixture_cloud_routes//30401/30500} ;;
        extra-route) fixture_cloud_routes+=$'\n172.16.0.0/12 via 172.30.143.129 dev test22 table 30401 proto 4 metric 10' ;;
        unrelated-table) fixture_cloud_routes+=$'\n192.0.2.0/24 dev test22 table 40000 proto 4 scope 253 metric 10' ;;
        duplicate-rule) fixture_rules+=$'\n30350: from all lookup main suppress_prefixlength 0 proto static' ;;
        unknown-owner) fixture_no_nm_owner=true ;;
        saved-policy) fixture_saved_policy='priority 100 from all table 100' ;;
        unreadable-policy) fixture_saved_policy_failure=true ;;
        late-saved-policy) fixture_late_saved_policy=true ;;
        saved-table) fixture_route_table=30401 ;;
        saved-auxiliary-route) printf '198.51.100.0/24 172.30.143.129 10 table=30401\n' > "$test_root/profiles/$(fixture_profile_uuid test22)" ;;
        temporary-profile) fixture_profile_directory=/run/NetworkManager/system-connections ;;
        no-autoconnect) fixture_autoconnect=no ;;
        failed-table-read) fixture_cloud_route_failure=true ;;
        late-rule) fixture_late_cloud_rule=true ;;
        late-route) fixture_late_cloud_route=true ;;
        late-address) fixture_late_cloud_address=true ;;
        host-sources) fixture_rules=${fixture_rules//172.30.143.132 /172.30.143.132\/32 }; fixture_rules=${fixture_rules//10.83.86.118 /10.83.86.118\/32 } ;;
        numeric-rules)
            fixture_rules=${fixture_rules//proto static/proto 4}
            fixture_rules=${fixture_rules/lookup local/lookup 255}; fixture_rules=${fixture_rules//lookup main/lookup 254}; fixture_rules=${fixture_rules/lookup default/lookup 253} ;;
    esac
    printf '%s\n' "$fixture_routes" > "$test_root/network"
    baseline=$fixture_routes; rules_snapshot=$fixture_rules; tables_snapshot=$fixture_cloud_routes
    if [[ $action == preview || $action == host-sources || $action == numeric-rules ]]; then
        simple_main --persist --map 172.30.143.132/32=172.16.0.0/12
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/nm-mutations ]] || fail 'Cloud policy preview mutated networking.'
    elif [[ $action == runtime ]]; then
        simple_main --apply --map 172.30.143.132/32=172.16.0.0/12
        applied=$(cat "$test_root/network")
        grep -Fxq '172.16.0.0/12 via 172.30.143.129 dev test22 proto 4 src 172.30.143.132 metric 42762' "$test_root/network" || fail 'Cloud runtime apply selected the wrong source or gateway.'
        [[ ! -s $test_root/nm-mutations ]] || fail 'Cloud runtime-only apply modified saved configuration.'
        simple_main --apply --map 172.30.143.132/32=172.16.0.0/12
        [[ $(cat "$test_root/network") == "$applied" && ! -s $test_root/nm-mutations ]] || fail 'Cloud runtime-only apply is not idempotent.'
        simple_main --rollback --apply
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/nm-mutations ]] || fail 'Cloud runtime rollback changed saved configuration or the baseline.'
    elif [[ $action == partial-apply ]]; then
        fixture_add_failure=172.16.0.0/12
        if simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12; then fail 'Cloud partial runtime failure was hidden.'; fi
        [[ $(cat "$test_root/network") == "$baseline" && -s $test_root/profiles/$(fixture_profile_uuid test22) ]] || fail 'Cloud partial failure did not retain the expected retryable saved route.'
        unset fixture_add_failure
        simple_main --rollback --apply
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/profiles/$(fixture_profile_uuid test22) ]] || fail 'Cloud rollback did not recover the partial apply.'
    elif [[ $action == workflow || $action == manual-route || $action == named-routes ]]; then
        if [[ $action == manual-route ]]; then ip -4 route add 172.16.0.0/12 via 172.30.143.129 dev test22 src 172.30.143.132 proto static metric 42762; fi
        simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12
        [[ $(grep -c '^172.16.0.0/12 ' "$test_root/network") == 1 ]] || fail 'Cloud apply duplicated or lost the aggregate route.'
        grep -Fxq '172.16.0.0/12 172.30.143.129 42762 table=254' "$test_root/profiles/$(fixture_profile_uuid test22)" || fail 'Cloud persistence used a policy table or pinned DHCP source.'
        applied=$(cat "$test_root/network"); mutations=$(cat "$test_root/nm-mutations")
        simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12
        [[ $(cat "$test_root/network") == "$applied" && $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Cloud persistent apply is not idempotent.'
        printf '%s\n' "$baseline" '172.16.0.0/12 via 172.30.143.129 dev test22 proto 4 metric 42762' > "$test_root/network"
        simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12
        [[ $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Cloud simulated DHCP boot required saved-route changes.'
        simple_main --rollback --apply
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/profiles/$(fixture_profile_uuid test22) ]] || fail 'Cloud rollback changed the baseline or retained saved routes.'
        simple_main --rollback --apply
        simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12
        ip -4 route add 172.31.0.0/16 via 172.30.143.129 dev test22 src 172.30.143.132 proto static metric 123
        simple_main --reset --apply
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/profiles/$(fixture_profile_uuid test22) ]] || fail 'Cloud reset changed defaults/connected routes or retained custom routes.'
        [[ $fixture_rules == "$rules_snapshot" && $fixture_cloud_routes == "$tables_snapshot" ]] || fail 'Cloud workflow changed source policy rules/tables.'
    else
        if simple_main --apply --persist --map 172.30.143.132/32=172.16.0.0/12; then fail "Unsafe cloud policy was admitted: $action"; fi
        [[ $(cat "$test_root/network") == "$baseline" && ! -s $test_root/nm-mutations ]] || fail "Rejected cloud policy changed networking: $action"
    fi
)
expect pass 'captured RHEL cloud policy previews unequal subnets with reordered NICs' cloud_policy_fixture
expect pass 'cloud policy accepts exact host selectors in source rules' cloud_policy_fixture host-sources
expect pass 'cloud policy accepts numeric standard tables and static protocol' cloud_policy_fixture numeric-rules
expect pass 'cloud runtime-only apply and rollback preserve profiles and are idempotent' cloud_policy_fixture runtime
expect pass 'cloud rollback recovers a partial persistent apply without changing source policy' cloud_policy_fixture partial-apply
expect pass 'cloud apply persistence idempotency simulated boot rollback and reset preserve source policy' cloud_policy_fixture workflow
expect pass 'cloud workflow accepts standard named protocol scope and main/local table aliases without -N' cloud_policy_fixture named-routes
expect pass 'existing matching manual cloud route can be persisted without duplication' cloud_policy_fixture manual-route
for cloud_case in unknown-protocol wrong-scope named-auxiliary-table extra-rule missing-suppress wrong-suppress missing-pair unknown-source subnet-source extra-selector missing-route wrong-subnet wrong-gateway wrong-device wrong-metric shared-table out-of-range-index extra-route unrelated-table duplicate-rule unknown-owner saved-policy unreadable-policy late-saved-policy saved-table saved-auxiliary-route temporary-profile no-autoconnect failed-table-read late-rule late-route late-address; do
    expect pass "cloud policy rejects $cloud_case before any writes" cloud_policy_fixture "$cloud_case"
done
for invalid in 0 -1 4294967296 00050 1+2; do expect fail "invalid metric $invalid" simple_main --apply --metric "$invalid" "${common[@]}"; done
expect pass 'maximum IPv4 metric preview' simple_main --metric 4294967295 "${common[@]}"
fixture_profile_directory=/run/NetworkManager/system-connections
expect fail 'temporary profile persistence refused' simple_main --apply --persist "${common[@]}"
grep -Fq 'PROFILE: interface=test22 uuid=22222222-2222-2222-2222-222222222222 storage=/run/NetworkManager/system-connections/test22.nmconnection' "$test_root/output" || fail 'Runtime storage diagnostic lost its profile identity.'
grep -Fq 'Known Issues' "$test_root/output" || fail 'Runtime storage diagnostic has no manual-preparation reference.'
unset fixture_profile_directory
profile_storage_diagnostic_fixture() (
    local scenario=$1 uuid baseline mutations
    uuid=$(fixture_profile_uuid test22)
    baseline=$(cat "$test_root/network"); mutations=$(cat "$test_root/nm-mutations")
    case $scenario in
        runtime) fixture_profile_storage_path='/run/NetworkManager/system-connections/Wired connection 1.nmconnection' ;;
        no-filename) fixture_profile_storage_path='' ;;
        dash-filename) fixture_profile_storage_path=-- ;;
        vendor) fixture_profile_storage_path=/usr/lib/NetworkManager/system-connections/vendor.nmconnection ;;
        missing) fixture_profile_match_mode=missing ;;
        duplicate) fixture_profile_match_mode=duplicate ;;
        read-failure) fixture_profile_storage_failure=true ;;
        keyfile) fixture_profile_storage_path=/etc/NetworkManager/system-connections/test22.nmconnection ;;
        ifcfg) fixture_profile_storage_path='/etc/sysconfig/network-scripts/ifcfg-Wired connection 1' ;;
    esac
    if [[ $scenario == keyfile || $scenario == ifcfg ]]; then
        simple_nm_profile test22 > "$test_root/profile-stdout" 2> "$test_root/profile-stderr"
        [[ $(cat "$test_root/profile-stdout") == "$uuid" && ! -s $test_root/profile-stderr ]] || fail 'Valid profile helper no longer returns only its UUID.'
    else
        if (simple_nm_profile test22) > "$test_root/profile-stdout" 2> "$test_root/profile-stderr"; then fail "Unsafe profile storage was admitted: $scenario"; fi
        [[ ! -s $test_root/profile-stdout ]] || fail 'Profile diagnostics polluted structured stdout.'
        grep -Fq 'interface=test22' "$test_root/profile-stderr" || fail 'Profile failure did not identify its interface.'
        grep -Fq "uuid=$uuid" "$test_root/profile-stderr" || fail 'Profile failure did not identify its UUID.'
        case $scenario in
            runtime)
                grep -Fq "storage=$fixture_profile_storage_path" "$test_root/profile-stderr" || fail 'Runtime filename with spaces was altered.'
                grep -Fq 'Profile storage is under /run' "$test_root/profile-stderr" || fail 'Runtime storage was not classified.'
                grep -Fq "sudo nmcli --fields connection,ipv4 connection show uuid $uuid" "$test_root/profile-stderr" || fail 'Missing read-only profile inspection guidance.'
                grep -Fq 'no profile is saved automatically' "$test_root/profile-stderr" || fail 'Manual guidance implies automatic preparation.' ;;
            no-filename|dash-filename) grep -Fq 'no profile filename' "$test_root/profile-stderr" || fail 'Missing filename was not classified.' ;;
            vendor) grep -Fq 'Storage outside /etc is not accepted' "$test_root/profile-stderr" || fail 'Vendor storage was misclassified as runtime.' ;;
            missing) grep -Fq 'matches=0 paths=(none)' "$test_root/profile-stderr" || fail 'Missing UUID match was not identified.' ;;
            duplicate)
                grep -Fq 'matches=2 paths=' "$test_root/profile-stderr" || fail 'Duplicate UUID match was not identified.'
                grep -Fq '/etc/NetworkManager/system-connections/duplicate.nmconnection' "$test_root/profile-stderr" || fail 'Duplicate match paths were not reported.' ;;
            read-failure) grep -Fq 'Cannot inspect profile storage' "$test_root/profile-stderr" || fail 'Storage read failure was hidden.' ;;
        esac
        if [[ $scenario == missing || $scenario == duplicate || $scenario == read-failure ]]; then
            if grep -Fq 'manual preparation' "$test_root/profile-stderr"; then fail 'Ambiguous/unreadable profile storage received preparation advice.'; fi
        fi
    fi
    [[ $(cat "$test_root/network") == "$baseline" && $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Profile inspection changed routes or saved settings.'
)
for profile_case in runtime no-filename dash-filename vendor missing duplicate read-failure keyfile ifcfg; do
    expect pass "profile storage diagnostics preserve safety and output contracts: $profile_case" profile_storage_diagnostic_fixture "$profile_case"
done
fixture_profile_directory=/run/NetworkManager/system-connections
expect fail 'runtime profile persistent preview reports guidance without preparing the profile' simple_main --persist "${common[@]}"
grep -Fq 'Known Issues' "$test_root/output" || fail 'Public preview lost runtime profile guidance.'
[[ $(cat "$test_root/network") == "$fixture_routes" && ! -s $test_root/nm-mutations ]] || fail 'Failed persistence preview prepared a profile or changed routes.'
expect pass 'runtime-only preview still accepts native NetworkManager with runtime profile storage' simple_main "${common[@]}"
if grep -Fq 'PROFILE:' "$test_root/output"; then fail 'Runtime-only preview acquired a persistence requirement.'; fi
unset fixture_profile_directory
fixture_autoconnect=no
expect fail 'non-autoconnect profile persistence refused' simple_main --apply --persist "${common[@]}"
unset fixture_autoconnect
fixture_ipv4_method=disabled
expect fail 'unsupported profile IPv4 method blocks persistence' simple_main --apply --persist "${common[@]}"
unset fixture_ipv4_method
fixture_method_failure=true
expect fail 'unreadable profile IPv4 method blocks persistence before mutation' simple_main --apply --persist "${common[@]}"
unset fixture_method_failure
for bad_live in \
    '172.16.0.0/16 via 172.16.0.129 dev test22 proto 4 src 172.16.0.133 metric 42762' \
    '172.16.0.0/16 via 172.16.0.130 dev test22 proto 4 metric 42762'; do
    printf '%s\n' "$fixture_routes" "$bad_live" > "$test_root/network"
    expect fail "runtime collision remains rejected: $bad_live" simple_main --apply --persist "${common[@]}"
done
printf '%s\n' "$fixture_routes" > "$test_root/network"
[[ $(cat "$test_root/network") == "$fixture_routes" && ! -s $test_root/nm-mutations ]] || fail 'Failed validation mutated networking.'

expect pass 'runtime apply skips absent maps and installs matches' simple_main --apply "${common[@]}" --map 172.24.0.0/16=172.24.0.0/16
grep -Fxq 'MODE: apply; operation=routes; persistence=no; runtime routes use ip' "$test_root/output" || fail 'Wrong runtime apply diagnostic.'
runtime=$(cat "$test_root/network")
[[ $(grep -c 'metric 42762' "$test_root/network") == 4 && ! -s $test_root/nm-mutations ]] || fail 'Wrong runtime apply.'
expect pass 'second runtime apply is idempotent' simple_main --apply "${common[@]}"
[[ $(cat "$test_root/network") == "$runtime" ]] || fail 'Repeated apply changed routes.'
expect pass 'runtime plan upgrades to persistence using exact /32 selectors' simple_main --apply --persist "${host_maps[@]}"
grep -Fxq 'MODE: apply; operation=routes; persistence=yes; runtime routes use ip' "$test_root/output" || fail 'Wrong persistent apply diagnostic.'
expect fail 'DHCP saved routes do not pin a preferred source' grep -q 'src=' "$test_root"/profiles/*
mutations=$(cat "$test_root/nm-mutations")
expect pass 'second persistent apply is idempotent' simple_main --apply --persist "${common[@]}"
[[ $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Repeated persistence changed profiles.'
saved_entry=$(cat "$test_root/profiles/$(fixture_profile_uuid test22)")
printf '%s\n' '172.16.0.0/16 172.16.0.129 42762 src=172.16.0.132 table=254' > "$test_root/profiles/$(fixture_profile_uuid test22)"
expect fail 'legacy DHCP preferred source requires reviewed cleanup' simple_main --apply --persist "${common[@]}"
[[ $(cat "$test_root/nm-mutations") == "$mutations" && $(cat "$test_root/network") == "$runtime" ]] || fail 'Legacy DHCP route was silently replaced.'
printf '%s\n' "$saved_entry" > "$test_root/profiles/$(fixture_profile_uuid test22)"
printf '%s\n' "$fixture_routes" > "$test_root/network"
for fixture_device in test22 test100 test180; do
    while read -r destination gateway metric preferred table; do
        [[ -n $destination ]] || continue
        if [[ $preferred == src=* ]]; then
            if [[ ${fixture_ipv4_method:-auto} == auto ]]; then
                printf '%s dev %s proto 4 scope 253 metric %s\n' "$gateway" "$fixture_device" "$metric" >> "$test_root/network"
                continue
            fi
            printf '%s via %s dev %s proto 4 src %s metric %s\n' "$destination" "$gateway" "$fixture_device" "${preferred#src=}" "$metric" >> "$test_root/network"
        else
            printf '%s via %s dev %s proto 4 metric %s\n' "$destination" "$gateway" "$fixture_device" "$metric" >> "$test_root/network"
        fi
    done < "$test_root/profiles/$(fixture_profile_uuid "$fixture_device")"
done
expect pass 'DHCP boot installs aggregates without waiting for a preferred source' test "$(grep -c 'via .*metric 42762' "$test_root/network")" -eq 4
boot_routes=$(cat "$test_root/network")
expect pass 'runtime reapply recognizes source-free routes after DHCP boot' simple_main --apply "${common[@]}"
expect pass 'persistent reapply after simulated reboot' simple_main --apply --persist "${common[@]}"
[[ $(cat "$test_root/network") == "$boot_routes" && $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Post-boot reapply changed existing routes.'
expect pass 'rollback preview is read-only' simple_main --rollback
grep -Fxq 'MODE: preview; operation=rollback; persistence=automatic-cleanup; runtime routes use ip' "$test_root/output" || fail 'Rollback diagnostic does not include automatic saved-route cleanup.'
[[ $(cat "$test_root/nm-mutations") == "$mutations" ]] || fail 'Cleanup preview mutated profiles.'
SSH_CONNECTION='10.0.2.4 12345 10.0.1.5 22'
expect fail 'cleanup apply refuses detected SSH' simple_main --rollback --apply
unset SSH_CONNECTION
expect pass 'rollback removes saved and active selected metric' simple_main --rollback --apply
[[ $(cat "$test_root/network") == "$fixture_routes" ]] || fail 'Rollback changed baseline.'
expect pass 'second rollback is a no-op' simple_main --rollback --apply
fixture_ipv4_method=manual
expect pass 'manual IPv4 profiles persist preferred sources' simple_main --apply --persist "${common[@]}"
expect pass 'manual saved route retains selected preferred source' grep -q 'src=172.16.0.132 table=254' "$test_root/profiles/$(fixture_profile_uuid test22)"
expect pass 'manual persistent routes roll back without changing the baseline' simple_main --rollback --apply
[[ $(cat "$test_root/network") == "$fixture_routes" ]] || fail 'Manual profile rollback changed the baseline.'
unset fixture_ipv4_method
expect pass 'custom metric persistent apply' simple_main --apply --persist --metric 50000 "${common[@]}"
expect pass 'default rollback preserves another metric' simple_main --rollback --apply
[[ $(grep -c 'metric 50000' "$test_root/network") == 4 ]] || fail 'Wrong metric removed.'
expect pass 'custom metric rollback' simple_main --rollback --metric 50000 --apply
[[ $(cat "$test_root/network") == "$fixture_routes" ]] || fail 'Custom metric rollback failed.'
printf '%s\n' '172.24.0.0/16 via 10.0.1.1 dev test180 proto 3' '172.25.0.0/16 dev test22 proto 4 scope 253 metric 70' '172.26.0.0/16 via 10.0.1.1 dev test180 proto 16 metric 42762' >> "$test_root/network"
printf '%s\n' '172.25.0.0/16 0.0.0.0 70' '0.0.0.0/0 172.16.0.129 42762' '172.27.0.0/16 172.16.0.129 42762 table=100' > "$test_root/profiles/$(fixture_profile_uuid test22)"
expect pass 'reset removes all custom metrics but retains DHCP defaults connected and non-main routes' simple_main --reset --apply
grep -Fxq 'MODE: apply; operation=reset; persistence=automatic-cleanup; runtime routes use ip' "$test_root/output" || fail 'Wrong reset apply diagnostic.'
[[ $(cat "$test_root/network") == "$fixture_routes"$'\n172.26.0.0/16 via 10.0.1.1 dev test180 proto 16 metric 42762' ]] || fail 'Reset changed protected runtime routes.'
[[ $(wc -l < "$test_root/profiles/$(fixture_profile_uuid test22)") == 2 ]] || fail 'Reset changed saved default/non-main routes.'
expect pass 'second reset is a no-op' simple_main --reset --apply
expect fail 'reset rejects misleading metric' simple_main --reset --metric 50000
expect fail 'cleanup modes are exclusive' simple_main --reset --rollback
expect fail 'cleanup rejects maps' simple_main --rollback "${common[@]}"

printf '%s\n' "$fixture_routes" '172.24.0.0/16 via 10.0.1.1 dev test180 proto 4 metric 42762' > "$test_root/network"
fixture_saved_read_limit=3
expect fail 'failed empty-profile recheck blocks mutation' simple_main --rollback --apply
unset fixture_saved_read_limit
grep -q '172.24.0.0/16' "$test_root/network" || fail 'Preflight failure removed a live route.'
expect pass 'cleanup retry after failed preflight' simple_main --rollback --apply
fixture_modify_failure=$(fixture_profile_uuid test100)
expect fail 'partial persistent failure is reported' simple_main --apply --persist "${common[@]}"
unset fixture_modify_failure
expect pass 'rollback recovers partial apply' simple_main --rollback --apply
cp -- "$script_path" "$test_root/renamed-tool"
expect pass 'renamed help uses invoked filename' bash "$test_root/renamed-tool" --help
grep -q 'Usage: bash renamed-tool ' "$test_root/output" || fail 'Help hardcodes script name.'
if grep -Eq 'azure-nic-routes\.sh|journal|/var/lib/' "$test_root/renamed-tool"; then fail 'Unexpected fixed filename or private state dependency.'; fi
fixture_native_generator=$(declare -f simple_netplan_generator)
simple_netplan_generator() {
    [[ $* == '--mapping test22' ]] || fail "Blocked unexpected Netplan generator command: $*"
    [[ ${fixture_netplan_failure:-false} != true ]] || return 1
    printf '%s\n' "$fixture_netplan_mapping"
}
simple_link_mac() { printf '%s\n' '70:a8:a5:4a:f3:51'; }
fixture_netplan_mapping='id=eth1, backend=networkd, set_name=test22, match_name=(null), match_mac=70:a8:a5:4a:f3:51, match_driver=hv_netvsc'
expect pass 'native Netplan maps opaque IDs by live MAC without parsing YAML' simple_netplan_mapping test22
[[ $(cat "$test_root/output") == eth1 ]] || fail 'Netplan mapping lost its definition ID.'
fixture_netplan_mapping=${fixture_netplan_mapping/networkd/NetworkManager}
expect fail 'Netplan mapping refuses an unsupported renderer' simple_netplan_mapping test22
fixture_netplan_mapping=${fixture_netplan_mapping/NetworkManager/networkd}
fixture_netplan_mapping=${fixture_netplan_mapping/70:a8:a5:4a:f3:51/70:a8:a5:4a:f3:52}
expect fail 'Netplan mapping refuses a different NIC MAC' simple_netplan_mapping test22
fixture_netplan_mapping=${fixture_netplan_mapping/70:a8:a5:4a:f3:52/(null)}
expect fail 'Netplan mapping refuses nonunique identity without an exact MAC' simple_netplan_mapping test22
fixture_netplan_mapping='id=eth1, backend=networkd, set_name=other, match_name=(null), match_mac=70:a8:a5:4a:f3:51, match_driver=hv_netvsc'
expect fail 'Netplan mapping refuses a pending rename' simple_netplan_mapping test22
fixture_netplan_mapping+=$'\nid=eth2, backend=networkd'
expect fail 'Netplan mapping refuses multiple result lines' simple_netplan_mapping test22
fixture_netplan_failure=true
expect fail 'Netplan mapping propagates native lookup failures' simple_netplan_mapping test22
unset fixture_netplan_failure
overlay_rows=$'172.16.0.0/16 172.16.0.129 42762 table=254\n172.24.0.0/16 172.16.0.129 50000 src=172.16.0.132 table=254'
expect pass 'route-only Netplan overlay contains no DHCP or interface settings' simple_netplan_render eth1 "$overlay_rows"
if grep -Eq 'dhcp|match:|renderer:|addresses:|nameservers:|mtu:|route-metric:' "$test_root/output"; then fail 'Overlay changes non-route configuration.'; fi
expect fail 'overlay rejects default routes' simple_netplan_render eth1 '0.0.0.0/0 172.16.0.129 42762 table=254'
expect fail 'overlay rejects unsupported route attributes' simple_netplan_render eth1 '172.16.0.0/16 172.16.0.129 42762 table=254 unsupported=yes'
expect fail 'overlay rejects definition ID injection' simple_netplan_render $'eth1\n  renderer: NetworkManager' "$overlay_rows"
expect fail 'overlay rejects invalid metrics' simple_netplan_render eth1 '172.16.0.0/16 172.16.0.129 0 table=254'
eval "$fixture_native_generator"
if [[ -x /usr/libexec/netplan/generate || -x /usr/lib/netplan/generate || -x /lib/netplan/generate ]]; then
        native_root="$test_root/native"
        mkdir -p -- "$native_root/etc/netplan" "$native_root/run" "$native_root/bin"
        printf '%s\n' '#!/bin/sh' 'case "$*" in is-system-running) printf "offline\n"; exit 1 ;; *) exit 99 ;; esac' > "$native_root/bin/systemctl"
        chmod 700 "$native_root/bin/systemctl"
        printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    eth1:' \
            '      match:' '        macaddress: "70:a8:a5:4a:f3:51"' '        driver: "hv_netvsc"' \
            '      dhcp4: true' '      dhcp4-overrides:' '        use-dns: false' \
            '        route-metric: 200' '      dhcp6: false' '      set-name: "eth1"' \
            '      routes:' '        - to: 172.30.0.0/16' '          via: 172.16.0.142' \
            '          metric: 77' > "$native_root/etc/netplan/50-cloud-init.yaml"
        chmod 600 "$native_root/etc/netplan/50-cloud-init.yaml"
        original_yaml=$(cksum < "$native_root/etc/netplan/50-cloud-init.yaml")
        PATH="$native_root/bin:$PATH" expect pass 'native Netplan compiles a cloud-init fixture without applying networking' simple_netplan_generator --root-dir "$native_root"
        compiled_network="$native_root/run/systemd/network/10-netplan-eth1.network"
        original_settings=$(awk 'BEGIN { section="" } /^\[/ { section=$0 } section != "[Route]" && NF { print }' "$compiled_network")
        simple_netplan_render eth1 "$overlay_rows" > "$native_root/etc/netplan/90-multinic-routes.yaml"
        chmod 600 "$native_root/etc/netplan/90-multinic-routes.yaml"
        PATH="$native_root/bin:$PATH" expect pass 'native Netplan merges route-only overlays with existing routes' simple_netplan_generator --root-dir "$native_root"
        expect pass 'generated route parser preserves existing route and preferred source' simple_networkd_routes "$compiled_network"
        grep -Fxq '172.30.0.0/16 172.16.0.142 77 table=254' "$test_root/output" || fail 'Overlay replaced an existing route.'
        grep -Fxq '172.16.0.0/16 172.16.0.129 42762 table=254' "$test_root/output" || fail 'DHCP-safe overlay route missing.'
        grep -Fxq '172.24.0.0/16 172.16.0.129 50000 src=172.16.0.132 table=254' "$test_root/output" || fail 'Manual preferred source missing.'
        [[ $(cksum < "$native_root/etc/netplan/50-cloud-init.yaml") == "$original_yaml" ]] || fail 'Native validation changed cloud-init YAML.'
        [[ $(awk 'BEGIN { section="" } /^\[/ { section=$0 } section != "[Route]" && NF { print }' "$compiled_network") == "$original_settings" ]] || fail 'Overlay changed non-route generated configuration.'
        rm -- "$native_root/etc/netplan/90-multinic-routes.yaml"
        PATH="$native_root/bin:$PATH" expect pass 'native overlay removal preserves the original route configuration' simple_netplan_generator --root-dir "$native_root"
        [[ $(simple_networkd_routes "$compiled_network") == '172.30.0.0/16 172.16.0.142 77 table=254' ]] || fail 'Overlay removal changed an unrelated route.'
        netplan_saved_inspection() (
            local simple_np_work='' simple_np_source='' simple_np_snapshot=''
            trap '[[ -z $simple_np_work ]] || rm -rf -- "$simple_np_work"' EXIT
            simple_system_root() { printf '%s\n' "$native_root"; }
            # Invoked indirectly by the sourced Netplan inspection helpers.
            # shellcheck disable=SC2317
            simple_netplan_trust() { [[ -r $1 && ! -L $1 ]] || fail 'Unsafe synthetic Netplan source.'; }
            simple_netplan_prepare
            simple_metric=42762
            local record='172.16.0.0/16|eth1|172.16.0.129|172.16.0.132|netplan:eth1'
            [[ $(simple_netplan_saved "$record") == absent ]] || fail 'Unexpected existing saved route.'
            simple_netplan_render eth1 '172.16.0.0/16 172.16.0.129 42762 table=254' > "$native_root/etc/netplan/90-multinic-eth1.yaml"
            chmod 600 "$native_root/etc/netplan/90-multinic-eth1.yaml"
            simple_netplan_refresh
            [[ $(simple_netplan_saved "$record") == present ]] || fail 'Owned saved route was not recognized.'
            [[ $(simple_netplan_saved_spec "$record") == '172.16.0.0/16 172.16.0.129 42762 table=254' ]] || fail 'DHCP source was pinned.'
            local unchanged_snapshot=$simple_np_snapshot
            simple_netplan_change eth1 '172.16.0.0/16 172.16.0.129 42762 table=254'
            [[ $simple_np_snapshot == "$unchanged_snapshot" ]] || fail 'Repeated overlay apply was not idempotent.'
            simple_saved_add '172.24.0.0/16|eth1|172.16.0.129|172.16.0.132|netplan:eth1'
            [[ $(simple_netplan_saved '172.24.0.0/16|eth1|172.16.0.129|172.16.0.132|netplan:eth1') == present ]] || fail 'Saved route addition failed.'
            simple_saved_remove netplan:eth1 '172.16.0.0/16 172.16.0.129 42762 table=254'
            [[ $(simple_netplan_saved "$record") == absent ]] || fail 'Exact saved route removal failed.'
            simple_saved_remove netplan:eth1 '172.24.0.0/16 172.16.0.129 42762 table=254'
            [[ ! -e $native_root/etc/netplan/90-multinic-eth1.yaml ]] || fail 'Empty route-only overlay was not removed.'
            [[ $(cksum < "$native_root/etc/netplan/50-cloud-init.yaml") == "$original_yaml" ]] || fail 'Route overlay writer changed cloud-init YAML.'
        )
        PATH="$native_root/bin:$PATH" expect pass 'native Netplan saved apply removal idempotency and DHCP safety preserve cloud-init' netplan_saved_inspection
else
        printf 'SKIP native Netplan overlay compilation: installed generator unavailable.\n'
fi
captured_debian_preview() {
    fixture_addresses=$'2: eth0 inet 10.0.0.6/29 metric 100 brd 10.0.0.7 scope global eth0\\ valid_lft forever preferred_lft forever\n3: eth2 inet 192.168.0.5/28 metric 300 brd 192.168.0.15 scope global eth2\\ valid_lft forever preferred_lft forever\n4: eth1 inet 172.16.0.5/29 metric 200 brd 172.16.0.7 scope global eth1\\ valid_lft forever preferred_lft forever'
    fixture_routes=$'default via 10.0.0.1 dev eth0 proto 16 src 10.0.0.6 metric 100\n172.16.0.0/29 dev eth1 proto 2 scope 253 src 172.16.0.5 metric 200\n192.168.0.0/28 dev eth2 proto 2 scope 253 src 192.168.0.5 metric 300\n168.63.129.16 via 10.0.0.1 dev eth0 proto 16 src 10.0.0.6 metric 100\n169.254.169.254 via 10.0.0.1 dev eth0 proto 16 src 10.0.0.6 metric 100\n10.0.0.0/29 dev eth0 proto 2 scope 253 src 10.0.0.6 metric 100\n10.0.0.1 dev eth0 proto 16 scope 253 src 10.0.0.6 metric 100'
    printf '%s\n' "$fixture_routes" > "$test_root/network"
    simple_metric=42762; simple_persist=false; simple_overrides=()
    simple_maps=('10.0.0.6/32=10.0.0.0/8' '172.16.0.5/32=172.16.0.0/12' '192.168.0.5/32=192.168.0.0/16')
    simple_inventory
    simple_plan
    [[ $(cat "$test_root/network") == "$fixture_routes" ]] || fail 'Captured preview changed routes.'
}
expect pass 'captured Debian 13 topology plans unequal prefixes without secondary defaults' captured_debian_preview
grep -Fq 'PRIMARY eth0 ' "$test_root/output" || fail 'Captured primary selection is incorrect.'
grep -Fq 'gateway=172.16.0.1 evidence=Azure-subnet-plus-one(172.16.0.5/29)' "$test_root/output" || fail 'Captured /29 gateway is incorrect.'
grep -Fq 'gateway=192.168.0.1 evidence=Azure-subnet-plus-one(192.168.0.5/28)' "$test_root/output" || fail 'Captured /28 gateway is incorrect.'
grep -Fq 'gateway=10.0.0.1 evidence=installed-default' "$test_root/output" || fail 'Captured installed primary gateway evidence was lost.'
if [[ -x /usr/libexec/netplan/generate || -x /usr/lib/netplan/generate || -x /lib/netplan/generate ]]; then
    netplan_fixture_root="$test_root/netplan-full"
    mkdir -p -- "$netplan_fixture_root/etc/netplan" "$netplan_fixture_root/active"
    captured_debian_preview >/dev/null
    simple_system_root() { printf '%s\n' "$netplan_fixture_root"; }
    simple_netplan_trust() { [[ -r $1 && ! -L $1 ]] || fail 'Unsafe synthetic Netplan source.'; }
    simple_link_mac() {
        case $1 in
            eth0) printf '60:45:bd:c1:2d:4d\n' ;;
            eth1) printf '70:a8:a5:4a:f3:51\n' ;;
            eth2) printf '7c:ed:8d:99:a1:76\n' ;;
            *) fail 'Unexpected synthetic interface.' ;;
        esac
    }
    printf 'network:\n  version: 2\n  ethernets:\n' > "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml"
    fixture_metric=100
    for fixture_device in eth0 eth1 eth2; do
        printf '    %s:\n      match:\n        macaddress: "%s"\n        driver: "hv_netvsc"\n      dhcp4: true\n      dhcp6: false\n      set-name: "%s"\n      dhcp4-overrides:\n        route-metric: %s\n' "$fixture_device" "$(simple_link_mac "$fixture_device")" "$fixture_device" "$fixture_metric" >> "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml"
        [[ $fixture_device == eth0 ]] || printf '        use-dns: false\n' >> "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml"
        fixture_metric=$((fixture_metric+100))
    done
    chmod 600 "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml"
    PATH="$native_root/bin:$PATH" simple_netplan_generator --root-dir "$netplan_fixture_root"
    cp -- "$netplan_fixture_root/run/systemd/network/"*.network "$netplan_fixture_root/active/"
    simple_networkd_configuration() {
        printf '# /run/systemd/network/10-netplan-%s.network\n' "$1"
        cat "$netplan_fixture_root/active/10-netplan-$1.network"
        [[ ${fixture_extra_dropin:-false} != true ]] || printf '# /etc/systemd/network/10-netplan-%s.network.d/custom.conf\n[Network]\nDNS=192.0.2.1\n' "$1"
        if [[ ${fixture_late_dropin:-false} == true ]]; then
            local reads=0
            [[ ! -f $test_root/manager-reads ]] || read -r reads < "$test_root/manager-reads"
            reads=$((reads+1)); printf '%s\n' "$reads" > "$test_root/manager-reads"
            ((reads <= 3)) || printf '# /etc/systemd/network/10-netplan-%s.network.d/custom.conf\n[Route]\nDestination=172.31.0.0/16\n' "$1"
        fi
    }
    nmcli() {
        if [[ $* == '--escape no -g GENERAL.CON-UUID device show '* && ${!#} == "${fixture_nm_claim:-}" ]]; then printf '22222222-2222-2222-2222-222222222222\n'; else return 1; fi
    }
    simple_netplan() {
        [[ $* == 'ip leases '* ]] || fail "Blocked unexpected Netplan CLI command: $*"
        [[ ${!#} != eth0 ]] || printf 'ROUTER=10.0.0.1\n'
    }
    netplan_maps=(--map 10.0.0.6/32=10.0.0.0/8 --map 172.16.0.5/32=172.16.0.0/12 --map 192.168.0.5/32=192.168.0.0/16)
    netplan_baseline=$(cat "$test_root/network")
    cloud_init_snapshot=$(sha256sum "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml")
    for fixture_os_case in ubuntu:24.04 ubuntu:26.04 debian:12 debian:14; do
        IFS=: read -r fixture_os_id fixture_os_version <<< "$fixture_os_case"
        fixture_os_like=''
        PATH="$native_root/bin:$PATH" expect pass "$fixture_os_id $fixture_os_version uses its supported Netplan/networkd backend" simple_main --persist "${netplan_maps[@]}"
        grep -Eq '^BACKEND eth1: Netplan -> systemd-networkd; compiler=(configure|generate)$' "$test_root/output" || fail 'OS metadata changed Netplan backend selection.'
    done
    fixture_os_id=debian; fixture_os_version=13
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public persistent preview verifies all three Netplan owners' simple_main --persist "${netplan_maps[@]}"
    grep -Fxq 'OS: ID=debian VERSION_ID=13 ID_LIKE=(not set)' "$test_root/output" || fail 'Public Debian preview lost its distro diagnostic.'
    grep -Eq '^BACKEND eth1: Netplan -> systemd-networkd; compiler=(configure|generate)$' "$test_root/output" || fail 'Missing verified Netplan backend/compiler diagnostic.'
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Netplan preview changed runtime routes.'
    if compgen -G "$netplan_fixture_root/etc/netplan/90-multinic-*.yaml" >/dev/null; then fail 'Netplan preview saved routes.'; fi
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public apply saves overlays and adds runtime routes' simple_main --apply --persist "${netplan_maps[@]}"
    [[ $(grep -c 'proto 4 .*metric 42762' "$test_root/network") == 3 ]] || fail 'Wrong Netplan runtime route count.'
    if grep -q 'from:' "$netplan_fixture_root/etc/netplan/"90-multinic-*.yaml; then fail 'Netplan DHCP overlay pinned a source.'; fi
    netplan_applied=$(cat "$test_root/network")
    overlay_snapshot=$(sha256sum "$netplan_fixture_root/etc/netplan/"*.yaml)
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public second persistent apply is idempotent' simple_main --apply --persist "${netplan_maps[@]}"
    [[ $(cat "$test_root/network") == "$netplan_applied" && $(sha256sum "$netplan_fixture_root/etc/netplan/"*.yaml) == "$overlay_snapshot" ]] || fail 'Repeated Netplan apply changed state.'
    PATH="$native_root/bin:$PATH" simple_netplan_generator --root-dir "$netplan_fixture_root"
    cp -- "$netplan_fixture_root/run/systemd/network/"*.network "$netplan_fixture_root/active/"
    printf '%s\n' "$netplan_baseline" > "$test_root/network"
    for fixture_device in eth0 eth1 eth2; do
        while read -r destination gateway metric attributes; do
            [[ -z $destination ]] || printf '%s via %s dev %s proto 4 metric %s\n' "$destination" "$gateway" "$fixture_device" "$metric" >> "$test_root/network"
        done < <(simple_networkd_routes "$netplan_fixture_root/active/10-netplan-$fixture_device.network")
    done
    netplan_applied=$(cat "$test_root/network")
    PATH="$native_root/bin:$PATH" expect pass 'Netplan post-boot reapply accepts source-free runtime routes' simple_main --apply --persist "${netplan_maps[@]}"
    [[ $(cat "$test_root/network") == "$netplan_applied" ]] || fail 'Post-boot Netplan reapply changed source-free routes.'
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public rollback preview is read-only' simple_main --rollback
    [[ $(cat "$test_root/network") == "$netplan_applied" ]] || fail 'Rollback preview changed runtime state.'
    fixture_require_saved_first=true
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public rollback removes saved overlays before live routes' simple_main --rollback --apply
    unset fixture_require_saved_first
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Netplan rollback changed defaults connected or platform routes.'
    [[ $(sha256sum "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml") == "$cloud_init_snapshot" ]] || fail 'Public Netplan workflow changed cloud-init settings.'
    if compgen -G "$netplan_fixture_root/etc/netplan/90-multinic-*.yaml" >/dev/null; then fail 'Netplan rollback left a saved overlay.'; fi
    PATH="$native_root/bin:$PATH" expect pass 'Debian 13 public repeated rollback is a no-op' simple_main --rollback --apply
    PATH="$native_root/bin:$PATH" expect pass 'Netplan custom metric persistence uses the same adapter' simple_main --apply --persist --metric 50000 "${netplan_maps[@]}"
    PATH="$native_root/bin:$PATH" expect pass 'Netplan default rollback preserves another custom metric' simple_main --rollback --apply
    [[ $(grep -c 'metric 50000' "$test_root/network") == 3 ]] || fail 'Default rollback removed another metric.'
    printf '172.24.0.0/16 via 10.0.0.1 dev eth0 proto 3\n' >> "$test_root/network"
    fixture_require_saved_first=true
    PATH="$native_root/bin:$PATH" expect pass 'Netplan reset removes owned overlays and manual runtime routes across metrics' simple_main --reset --apply
    unset fixture_require_saved_first
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Netplan reset changed protected runtime routes.'
    PATH="$native_root/bin:$PATH" expect pass 'Netplan repeated reset is a no-op' simple_main --reset --apply
    fixture_add_failure=172.16.0.0/12
    PATH="$native_root/bin:$PATH" expect fail 'Netplan partial runtime apply failure is reported' simple_main --apply --persist "${netplan_maps[@]}"
    unset fixture_add_failure
    fixture_require_saved_first=true
    PATH="$native_root/bin:$PATH" expect pass 'Netplan saved-first rollback recovers a partial persistent apply' simple_main --rollback --apply
    unset fixture_require_saved_first
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Partial Netplan recovery changed protected routes.'
    fixture_nm_claim=eth1
    PATH="$native_root/bin:$PATH" expect fail 'Two managers claiming one interface fail before writes' simple_main --apply --persist "${netplan_maps[@]}"
    unset fixture_nm_claim
    fixture_extra_dropin=true
    PATH="$native_root/bin:$PATH" expect fail 'Uninspected networkd drop-ins fail before writes' simple_main --apply --persist "${netplan_maps[@]}"
    unset fixture_extra_dropin
    fixture_late_dropin=true
    PATH="$native_root/bin:$PATH" expect fail 'A route-only drop-in appearing after planning blocks all writes' simple_main --apply --persist "${netplan_maps[@]}"
    unset fixture_late_dropin
    PATH="$native_root/bin:$PATH" expect fail 'Netplan rejects metrics its native serializer cannot retain' simple_main --apply --persist --metric 4294967295 "${netplan_maps[@]}"
    simple_netplan_render eth1 '172.16.0.0/12 172.16.0.1 42762 table=254' > "$netplan_fixture_root/etc/netplan/70-external.yaml"
    chmod 600 "$netplan_fixture_root/etc/netplan/70-external.yaml"
    PATH="$native_root/bin:$PATH" expect fail 'Matching external Netplan saved routes are not silently adopted' simple_main --apply --persist "${netplan_maps[@]}"
    PATH="$native_root/bin:$PATH" expect fail 'Netplan rollback refuses matching external saved routes before live deletion' simple_main --rollback --apply
    PATH="$native_root/bin:$PATH" expect fail 'Netplan reset refuses external saved routes rather than claiming success' simple_main --reset --apply
    simple_netplan_render eth2 '172.16.0.0/13 192.168.0.1 77 table=254' > "$netplan_fixture_root/etc/netplan/70-external.yaml"
    PATH="$native_root/bin:$PATH" expect fail 'More-specific pending routes on another NIC block the whole plan' simple_main --apply --persist "${netplan_maps[@]}"
    printf 'network:\n  version: 2\n  ethernets:\n    eth1:\n      routing-policy:\n        - from: 172.16.0.5\n          table: 100\n          priority: 100\n' > "$netplan_fixture_root/etc/netplan/70-external.yaml"
    PATH="$native_root/bin:$PATH" expect fail 'Pending saved policy rules block mutation even before activation' simple_main --apply --persist "${netplan_maps[@]}"
    printf 'network: [invalid\n' > "$netplan_fixture_root/etc/netplan/70-external.yaml"
    PATH="$native_root/bin:$PATH" expect fail 'Invalid native Netplan sources fail before mutation' simple_main --apply --persist "${netplan_maps[@]}"
    rm -- "$netplan_fixture_root/etc/netplan/70-external.yaml"
    ln -s 50-cloud-init.yaml "$netplan_fixture_root/etc/netplan/70-external.yaml"
    PATH="$native_root/bin:$PATH" expect fail 'Symlinked Netplan configuration fails before mutation' simple_main --apply --persist "${netplan_maps[@]}"
    rm -- "$netplan_fixture_root/etc/netplan/70-external.yaml"
    [[ $(cat "$test_root/network") == "$netplan_baseline" && $(sha256sum "$netplan_fixture_root/etc/netplan/50-cloud-init.yaml") == "$cloud_init_snapshot" ]] || fail 'Failed preflights mutated protected state.'
    if compgen -G "$netplan_fixture_root/etc/netplan/90-multinic-*.yaml" >/dev/null; then fail 'Failed preflights saved an overlay.'; fi
    printf 'network:\n  version: 2\n  ethernets:\n    eth1:\n      dhcp4: false\n      addresses: [172.16.0.5/29]\n' > "$netplan_fixture_root/etc/netplan/70-manual.yaml"
    chmod 600 "$netplan_fixture_root/etc/netplan/70-manual.yaml"
    PATH="$native_root/bin:$PATH" simple_netplan_generator --root-dir "$netplan_fixture_root"
    cp -- "$netplan_fixture_root/run/systemd/network/"*.network "$netplan_fixture_root/active/"
    PATH="$native_root/bin:$PATH" expect pass 'Manual Netplan profiles save the selected preferred source' simple_main --apply --persist "${netplan_maps[@]}"
    grep -Fq 'from: 172.16.0.5' "$netplan_fixture_root/etc/netplan/90-multinic-eth1.yaml" || fail 'Manual Netplan preferred source is missing.'
    PATH="$native_root/bin:$PATH" expect pass 'Manual Netplan routes roll back without changing source profiles' simple_main --rollback --apply
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Manual Netplan rollback changed protected routes.'
    rm -- "$netplan_fixture_root/etc/netplan/70-manual.yaml"
    PATH="$native_root/bin:$PATH" simple_netplan_generator --root-dir "$netplan_fixture_root"
    cp -- "$netplan_fixture_root/run/systemd/network/"*.network "$netplan_fixture_root/active/"
    PATH="$native_root/bin:$PATH" expect pass 'Netplan can reapply after manual-profile cleanup' simple_main --apply --persist "${netplan_maps[@]}"
    netplan_applied=$(cat "$test_root/network")
    fixture_native_commit=$(declare -f simple_netplan_commit)
    simple_netplan_commit() {
        [[ ${fixture_commit_failure:-} != "${1##*/}" ]] || return 1
        if [[ -z $2 ]]; then rm -- "$1"; else cp -- "$2" "$1"; fi
    }
    fixture_commit_failure=90-multinic-eth2.yaml
    PATH="$native_root/bin:$PATH" expect fail 'Netplan saved removal failure leaves live routes intact' simple_main --rollback --apply
    [[ $(cat "$test_root/network") == "$netplan_applied" ]] || fail 'Saved failure allowed live route deletion.'
    unset fixture_commit_failure
    eval "$fixture_native_commit"
    fixture_require_saved_first=true
    PATH="$native_root/bin:$PATH" expect pass 'Netplan rollback retries after a partial saved removal failure' simple_main --rollback --apply
    unset fixture_require_saved_first
    [[ $(cat "$test_root/network") == "$netplan_baseline" ]] || fail 'Saved cleanup retry changed the baseline.'
fi
printf '%s isolated Bash checks passed; no OS networking commands executed.\n' "$passed"