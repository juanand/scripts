#!/usr/bin/env bash

set -euo pipefail

command -v fold >/dev/null 2>&1 || {
    printf '%s\n' 'Error: Missing required utility: fold' >&2
    exit 1
}

message() {
    printf '%s\n' "$@" | fold -s -w 78
}

fail() {
    message "Error: $1" >&2
    exit 1
}

certificate_thumbprint() {
    local fingerprint
    fingerprint=$(openssl x509 "$@" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fingerprint=${fingerprint#*=}
    fingerprint=${fingerprint//:/}
    [[ $fingerprint =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "${fingerprint,,}"
}

describe_certificate() {
    local certificate=$1 details extension label fingerprint
    details=$(openssl x509 -in "$certificate" -noout -nameopt RFC2253 \
        -subject -issuer -dates 2>/dev/null) ||
        fail "Cannot read certificate details: $certificate"
    printf '%s\n' "$details"
    fingerprint=$(certificate_thumbprint -in "$certificate") ||
        fail "Cannot read certificate thumbprint: $certificate"
    printf 'SHA-256 thumbprint:\n  %s\n' "${fingerprint^^}"
    for extension in subjectKeyIdentifier authorityKeyIdentifier; do
        case $extension in
            subjectKeyIdentifier) label='Subject Key Identifier' ;;
            authorityKeyIdentifier) label='Authority Key Identifier' ;;
        esac
        details=$(openssl x509 -in "$certificate" -noout -ext "$extension" 2>/dev/null) ||
            fail "Cannot read $label from $certificate"
        if [[ $details == *'X509v3 '* ]]; then
            printf '%s\n' "$details"
        else
            printf '%s: not present\n' "$label"
        fi
    done
}

scan_certificate_file() {
    local source=$1 line ending normalized block='' end_marker='' fingerprint
    scan_original=''
    scan_contents=''
    scan_count=0
    scan_matches=0
    scan_other_blocks=0
    scan_der=''
    scan_delete=0
    scan_hashes=()
    [[ -f $source && -r $source ]] || fail "Not a readable certificate source: $source"
    if ! grep -aqE '^-----BEGIN (TRUSTED )?CERTIFICATE-----' -- "$source"; then
        if fingerprint=$(certificate_thumbprint -inform DER -in "$source"); then
            scan_der=$fingerprint
            scan_hashes+=("$fingerprint")
            scan_count=1
            if [[ -n ${removal_thumbprints["$fingerprint"]+present} ]]; then
                scan_matches=1
                scan_delete=1
            fi
        fi
        return
    fi
    while true; do
        line=''
        if IFS= read -r line; then
            ending=$'\n'
        else
            [[ -n $line ]] || break
            ending=''
        fi
        normalized=${line%$'\r'}
        scan_original+="$line$ending"
        if [[ -n $end_marker ]]; then
            [[ $normalized != '-----BEGIN '* ]] || fail "Nested PEM certificate in $source"
            block+="$line$ending"
            if [[ $normalized == "$end_marker" ]]; then
                fingerprint=$(printf '%s' "$block" | certificate_thumbprint) ||
                    fail "Invalid PEM certificate in $source"
                scan_hashes+=("$fingerprint")
                scan_count=$((scan_count + 1))
                if [[ -n ${removal_thumbprints["$fingerprint"]+present} ]]; then
                    scan_matches=$((scan_matches + 1))
                else
                    scan_contents+="$block"
                fi
                block=''
                end_marker=''
            fi
        else
            case $normalized in
                '-----BEGIN CERTIFICATE-----')
                    block=$line$ending
                    end_marker='-----END CERTIFICATE-----' ;;
                '-----BEGIN TRUSTED CERTIFICATE-----')
                    block=$line$ending
                    end_marker='-----END TRUSTED CERTIFICATE-----' ;;
                '-----END CERTIFICATE-----'|'-----END TRUSTED CERTIFICATE-----')
                    fail "Unexpected PEM certificate terminator in $source" ;;
                *)
                    if [[ $normalized == '-----BEGIN '* ]]; then
                        scan_other_blocks=1
                    fi
                    scan_contents+="$line$ending" ;;
            esac
        fi
    done < "$source"
    [[ -z $end_marker ]] || fail "Unclosed PEM certificate in $source"
    if (( scan_matches > 0 && scan_matches == scan_count && scan_other_blocks == 0 )); then
        scan_delete=1
    fi
}

check_directory_chain() {
    local directory=$1
    while [[ $directory != / ]]; do
        [[ ! -L $directory ]] || fail "Refusing a symbolic-link destination directory: $directory"
        [[ ! -e $directory || -d $directory ]] || fail "Not a directory: $directory"
        directory=${directory%/*}
        directory=${directory:-/}
    done
}

cleanup_removal() {
    if (( ${#removal_temporary_files[@]} > 0 )); then
        rm -f -- "${removal_temporary_files[@]}"
    fi
}

replace_contents() {
    local target=$1 contents=$2 temporary
    temporary=$(mktemp "${target%/*}/.installcert-remove.XXXXXXXX")
    removal_temporary_files+=("$temporary")
    cp --preserve=all -- "$target" "$temporary"
    printf '%s' "$contents" > "$temporary"
    mv -fT -- "$temporary" "$target"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -F -- "$target"
    fi
}

remove_selected_actions() {
    local root source resolved certificate details
    local match_count=0
    local -a link_sources=() regular_sources=()
    local -A originals=() replacements=() der_sources=() deletions=() input_sources=()
    removal_thumbprints=()
    for certificate in "${certificates[@]}"; do
        scan_certificate_file "$certificate"
        [[ $scan_count == 1 && -z $scan_der ]] ||
            fail "Expected one PEM certificate per removal input: $certificate"
        removal_thumbprints["${scan_hashes[0]}"]=1
        resolved=$(readlink -f -- "$certificate")
        input_sources["$resolved"]=1
        details=$(describe_certificate "$certificate")
        message '' 'Certificate selected for removal (input file is kept):' \
            "Source: $certificate" "$details"
    done
    for root in "${removal_directories[@]}"; do
        [[ -e $root || -L $root ]] || continue
        check_directory_chain "$root"
        while IFS= read -r -d '' source; do
            [[ -n $source ]] || fail "Cannot read all trust-source entries under $root"
            [[ -f $source ]] || continue
            scan_certificate_file "$source"
            (( scan_matches > 0 )) || continue
            resolved=$(readlink -f -- "$source")
            [[ -z ${input_sources["$resolved"]+present} ]] ||
                fail 'A removal input is also a trust source. Move the input directory outside the trust-source directories.'
            check_directory_chain "${source%/*}"
            originals["$source"]=$scan_original
            replacements["$source"]=$scan_contents
            der_sources["$source"]=$scan_der
            deletions["$source"]=$scan_delete
            if [[ -L $source ]]; then
                link_sources+=("$source")
            else
                regular_sources+=("$source")
            fi
            match_count=$((match_count + scan_matches))
            message "Match: $scan_matches certificate(s) in $source"
        done < <(find "$root" \( -type f -o -type l \) -print0 2>/dev/null || printf '\0')
    done
    message "Selected certificates: ${#removal_thumbprints[@]}" \
        "Matching certificates in trust sources: $match_count" \
        "System CA bundle: $bundle" "Trust update: ${removal_update_command[*]}"
    if (( ! apply_changes )); then
        message 'Removal preview complete. No changes made.' \
            'Add --apply to remove the matching certificates.'
        return
    fi
    (( EUID == 0 )) || fail 'Removal requires root. Rerun with sudo; automatic elevation is not performed.'

    for source in "${link_sources[@]}" "${regular_sources[@]}"; do
        scan_certificate_file "$source"
        [[ $scan_original == "${originals["$source"]}" && $scan_der == "${der_sources["$source"]}" ]] ||
            fail "Trust source changed during preflight: $source. No changes made."
    done
    trap cleanup_removal EXIT
    for source in "${link_sources[@]}" "${regular_sources[@]}"; do
        if (( ${deletions["$source"]} )); then
            rm -f -- "$source"
        else
            replace_contents "$source" "${replacements["$source"]}"
        fi
        message "Removed matching certificate data from: $source"
    done
    if ! "${removal_update_command[@]}" 2>&1 | fold -s -w 78; then
        fail 'Trust update failed after source changes. Retry --removecerts --apply to finish rebuilding trust.'
    fi
    [[ -f $bundle && -r $bundle ]] ||
        fail 'Certificate cleanup finished, but the rebuilt system CA bundle cannot be inspected.'
    scan_certificate_file "$bundle"
    (( scan_matches == 0 )) ||
        fail 'Selected certificates remain in the rebuilt CA bundle. Inspect other trust-policy sources; removal is incomplete.'
    message 'Matching certificates removed and system trust rebuilt.' \
        'The input certs directory was not changed.'
    message 'No backup directory was created. No services or service managers were restarted or reloaded.'
}

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
    fail 'Bash 4.4 or later is required.'
declare -A removal_thumbprints=()
removal_temporary_files=()
apply_changes=0
remove_certs=0
apply_certs=0
(( $# > 0 )) || set -- --help
while (( $# > 0 )); do
case $1 in
    --apply) apply_changes=1; shift ;;
    --removecerts) remove_certs=1; shift ;;
    --installcerts) apply_certs=1; shift ;;
    --help|-h)
        message "Usage: bash \"${0##*/}\" ACTION [--apply]" \
            '' \
            'No arguments show this help only, even when running as root.' \
            'Actions preview by default. Add --apply to install or remove anything.' \
            '' \
            'Actions:' \
            '  --installcerts   Install certificates and rebuild system trust only.' \
            '  --removecerts    Remove certificates selected by certs/*.crt only.' \
            '' \
            'Options:' \
            '  --apply          Execute the selected actions instead of previewing.' \
            '  --help, -h       Show this help.' \
            '' \
            'Installation:' \
            'Nothing is installed unless an action and --apply are selected.' \
            '--installcerts copies certs/*.crt unchanged; it does not change environment settings.' \
            'Removal actions cannot be combined with installation actions.' \
            'Certificate installation requires OpenSSL and one readable PEM certificate per .crt file.' \
            'Both preview and apply show subject, issuer, validity dates, SHA-256 thumbprint, key identifiers, source, destination, and bundle path.' \
            'Parsing certificate data does not establish CA suitability or trust.' \
            '' \
            'Removal:' \
            '--removecerts does not inspect or change environment configuration.' \
            'Both preview and apply show the same certificate details as installation for each removal input.' \
            'Matches SHA-256 certificate thumbprints, not filenames or file hashes.' \
            'Metadata before PEM headers and different PEM formatting do not change certificate identity.' \
            'Removes matching local and vendor CA sources, even if installed by another tool.' \
            'Mixed PEM files keep unrelated certificates. The input certs directory is unchanged.' \
            'Certificate removal requires OpenSSL; no backup or state directory is created.' \
            'Does not scan private application stores or p11-kit policy files.' \
            'Package updates may restore vendor certificates. Overwritten certificates cannot be restored.' \
            '' \
            'Scope:' \
            'This script does not install, remove, or migrate environment variables or application configuration.' \
            'See the README for optional client trust settings and manual cleanup of older configuration.' \
            'No runtime installations, proxy changes, TLS verification bypasses, or automatic service restarts.'
        exit 0 ;;
    *) fail 'Unknown argument. Use --help.' ;;
esac
done
if (( remove_certs && apply_certs )); then
    fail '--removecerts cannot be combined with --installcerts.'
fi
(( remove_certs || apply_certs )) ||
    fail 'Select an installation or removal action. --apply alone does not select an action. Use --help for usage.'
if (( apply_changes )); then
    message 'Mode: APPLY - selected changes will be made after preflight.'
else
    message 'Mode: PREVIEW - no changes will be made.'
fi
[[ $(uname -s) == Linux ]] || fail 'Run this script on Linux.'

for utility in cp chmod mkdir dirname awk mktemp mv rm openssl grep; do
    command -v "$utility" >/dev/null 2>&1 || fail "Missing required utility: $utility"
done
if (( remove_certs )); then
    for utility in find readlink; do
        command -v "$utility" >/dev/null 2>&1 || fail "Missing required utility: $utility"
    done
fi
[[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
os_name=$(awk -F= '/^PRETTY_NAME=/ { value = substr($0, index($0, "=") + 1); gsub(/["\047]/, "", value); print value }' /etc/os-release)
message "Detected OS: ${os_name:-Linux}"
os_family=$(awk -F= '/^(ID|ID_LIKE)=/ { gsub(/["\047]/, "", $2); printf " %s ", $2 }' /etc/os-release)
case $os_family in
    *' debian '*|*' ubuntu '*|*' linuxmint '*)
        trust_directory=/usr/local/share/ca-certificates
        bundle=/etc/ssl/certs/ca-certificates.crt
        removal_directories=(/usr/local/share/ca-certificates /usr/share/ca-certificates)
        removal_update_command=(update-ca-certificates --fresh)
        update_command=(update-ca-certificates) ;;
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*)
        trust_directory=/etc/pki/ca-trust/source/anchors
        bundle=/etc/pki/tls/certs/ca-bundle.crt
        removal_directories=(/etc/pki/ca-trust/source/anchors /usr/share/pki/ca-trust-source/anchors)
        removal_update_command=(update-ca-trust extract)
        update_command=(update-ca-trust extract) ;;
    *) fail 'Unsupported OS family; expected Debian/Ubuntu/Mint or RHEL/Rocky/AlmaLinux/Fedora.' ;;
esac
command -v "${update_command[0]}" >/dev/null 2>&1 || fail "Missing ${update_command[0]}; install the distribution ca-certificates package."

certificates=()
declare -A certificate_details=()
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
shopt -s nullglob
certificates=("$script_directory"/certs/*.crt)
(( ${#certificates[@]} > 0 )) || fail 'No certs/*.crt files found beside the script. Use .crt filenames for PEM CA certificates.'
[[ ! -L $trust_directory ]] || fail 'The certificate destination must not be a symbolic link.'
for certificate in "${certificates[@]}"; do
    [[ -f $certificate && -r $certificate && ! -L $certificate ]] || fail "Not a readable regular certificate file: $certificate"
    (( remove_certs )) && continue
    scan_certificate_file "$certificate"
    [[ $scan_count == 1 && -z $scan_der ]] ||
        fail "Expected one PEM certificate per installation input: $certificate"
    certificate_details["$certificate"]=$(describe_certificate "$certificate")
    destination=$trust_directory/${certificate##*/}
    [[ ! -L $destination ]] || fail 'A certificate destination is a symbolic link.'
    [[ ! -e $destination || -f $destination ]] || fail "Not a regular destination file: $destination"
done

if (( remove_certs )); then
    remove_selected_actions
    exit 0
fi

message "Certificates selected for installation: ${#certificates[@]}"
for certificate in "${certificates[@]}"; do
    destination=$trust_directory/${certificate##*/}
    message '' "Source: $certificate" "Destination: $destination" \
        "${certificate_details["$certificate"]}"
    if [[ -e $destination ]]; then
        message 'An existing destination file will be overwritten.'
    fi
done
message '' "System CA bundle: $bundle" "Trust update: ${update_command[*]}" \
    'Certificate data parsed successfully. CA suitability and trust were not validated.'
if (( ! apply_changes )); then
    message 'Preview complete. No changes made.' \
        'Add --apply to execute the selected installation actions.'
    exit 0
fi
(( EUID == 0 )) || fail 'Installing certificates requires root. Rerun with sudo; automatic elevation is not performed.'

mkdir -p -m 0755 -- "$trust_directory"
for certificate in "${certificates[@]}"; do
    cp -f -- "$certificate" "$trust_directory/${certificate##*/}"
    chmod 0644 -- "$trust_directory/${certificate##*/}"
    message "Installed certificate: $trust_directory/${certificate##*/}"
done
if command -v restorecon >/dev/null 2>&1; then
    for certificate in "${certificates[@]}"; do
        restorecon -F -- "$trust_directory/${certificate##*/}"
    done
fi
"${update_command[@]}" 2>&1 | fold -s -w 78
[[ -s $bundle && -r $bundle ]] || fail 'The trust updater did not produce the expected readable system CA bundle.'
message 'Certificates copied and system trust rebuilt.' "System CA bundle: $bundle"
 