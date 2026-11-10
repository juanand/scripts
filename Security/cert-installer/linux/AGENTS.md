# Agent Guidelines

## Scope

- These guidelines apply to `linux/` only. Maintain a certificate-only Bash installer for trusted CA certificates on Debian and RHEL Linux families; do not introduce an application framework.
- Neither action may inspect, create, modify, remove, or migrate environment settings, JVM options, shell profiles, service-manager configuration, or ownership markers.
- Do not require Java or running systemd, install packages or runtimes, automatically elevate privileges, change proxies, disable TLS verification, or reload/restart services.
- Keep [README.md](README.md) as the user/administrator guide and maintain [manual client trust guidance](README.md#Manual-Client-Trust-Configuration) there, backed by official client/runtime references.

## Behavioral Invariants

- Derive help from the current invocation name; the script must remain renameable. Use `{scriptname}` placeholders in administrator command examples.
- No arguments must show help only, regardless of privileges. Support only `--installcerts` and `--removecerts` actions. Require root and `--apply` with an explicit action to make changes; reject conflicting actions and all retired aliases.
- Without `--apply`, both actions preview and are strictly read-only, even as root: no temporary files, certificate copying/removal, trust-update invocation, or other mutations.
- Keep all user-facing output, including trust-updater output, within 78 columns. Report the detected OS before distribution-specific preflight checks.
- Both actions must show subject, issuer, validity dates, SHA-256 thumbprint, subject/authority key identifiers, input source, and bundle path in preview and apply modes. Reuse the same metadata helper. Installation must show the full destination; removal must distinguish kept inputs from matched installed paths and show selected details even with no matches.
- Removal matches decoded X.509 SHA-256 thumbprints regardless of installation provenance, not filenames or file hashes. Preserve unrelated certificates and other PEM blocks, and leave input files unchanged.
- Removal must not create persistent state or backup directories. Verify selected certificates are absent from the rebuilt PEM bundle before reporting success.
- Make repeated installation and removal runs idempotent.

## Shell Conventions

- Use Bash 4.4 or later, quoted expansions, arrays for file lists and commands, and deliberate error handling under `set -euo pipefail`.
- Discover `certs/*.crt` relative to the script's location, not the caller's working directory. Reject input symlinks; handle spaces, empty matches, unreadable inputs, and unsafe destination symlinks explicitly.
- Parse exactly one PEM/base64-encoded certificate per input before writes. An extension does not establish encoding, and parsing does not establish CA suitability, validity, or issuer trust. Copy accepted certificates without changing their bytes.
- Detect the family using `ID` and `ID_LIKE` in `/etc/os-release`. Check prerequisites, including the trust-update utility, before changing system state; reject unsupported distributions clearly.
- Use the distribution's trust updater for the selected action; never edit generated bundles directly. See the README for [trust-source coverage and removal limitations](README.md#removal-actions) and [bundle paths](README.md#pem-bundles-and-java-trust-stores).

## Verification

- There is no automated test suite. After script changes, run Bash syntax checks, then ShellCheck when installed. Use a Linux Bash environment; prefer WSL when developing on Windows/PowerShell. Report missing tools.
- Never use installation or removal as a syntax check, or source the top-level installer as a test helper.
- Run installation or removal with `--apply` only with explicit authorization in disposable Debian-family and RHEL-family Linux systems, never against the development host's trust store.

Run checks from this directory, substituting the current filename if renamed:

```bash
bash -n ./cert-installer.sh
shellcheck ./cert-installer.sh
```

For behavioral changes, use guarded temporary fixtures to check the affected cases:

- No-argument help and both previews as a normal user and root, with mutation commands blocked; usage errors and rejection of retired options.
- Repeated runs, renamed scripts, invocation from another directory, spaces in paths, missing/malformed/multiple input certificates, and symlink safety.
- Certificate metadata, absent key identifiers, and output width; byte-preserved inputs, mixed-certificate/other-PEM-block preservation, and unchanged legacy environment/profile/systemd files.
- Post-update removal verification, including failure when a selected certificate remains in the rebuilt bundle.

Report commands actually run, results, and remaining gaps. Distinguish syntax/lint and fixture evidence from real distribution trust-updater integration and application trust; stubbed updaters do not prove either.
