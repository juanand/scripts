# Install and Remove Trusted CA Certificates

This human-tested, vibe-coded script installs or removes local CA certificates on Debian/Ubuntu and RHEL/Fedora systems from the script-relative `./certs` folder. Every action previews by default, including when run with sudo; add `--apply` to make changes. Without parameters it only displays help. Certificate removal matches certificate thumbprints without requiring installation records or a backup directory.

The script manages certificates only. It never installs, removes, or migrates environment variables, shell profiles, or systemd configuration. Optional client-specific settings are documented in [Manual Client Trust Configuration](#manual-client-trust-configuration).

## Requirements

- Linux with Bash 4.4 or later and standard GNU utilities including `fold`.
- Both actions require OpenSSL and the distribution's `ca-certificates` package and trust-update command, including for preview. Java and systemd are not required.
- Root privileges when using `--apply` to install or remove anything. Preview does not require root if the files needed by the selected action are readable. Help does not require root.
- Certificate installation and removal require one PEM/base64-encoded CA certificate per lowercase `.crt` file in a `certs` directory beside the script. Input symlinks, malformed certificates, and multiple certificates per input file are rejected. Parsing does not establish CA suitability, validity dates, or issuer trust; review these independently.

Only install CAs you have independently verified, including their encoding, CA suitability, validity dates, and issuer. Installation changes trust system-wide.

## Usage

Choose an explicit action and place the selected CA certificates in the adjacent `certs` directory. Filenames and directory paths may contain spaces.

Replace `{scriptname}` in the examples with your chosen script basename, without a final `.sh` suffix. The examples assume the script has that suffix; omit it from the commands if your script is extensionless.

```bash
bash "./{scriptname}.sh"
bash "./{scriptname}.sh" --help
bash "./{scriptname}.sh" --installcerts
sudo bash "./{scriptname}.sh" --installcerts --apply
bash "./{scriptname}.sh" --removecerts
sudo bash "./{scriptname}.sh" --removecerts --apply
```

`--installcerts` selects certificate copying and trust rebuilding; `--removecerts` selects thumbprint-based removal and trust rebuilding. They cannot be combined. The former variable actions and combined "all" actions are no longer supported.

Selecting an action only previews its plan. Add `--apply` to execute it; this applies equally to installation and removal. Running as root or using sudo does not bypass preview mode. No arguments show help, and `--apply` alone is a usage error because it selects no action. The previous installation switch names and opt-out validation switch are no longer accepted.

The script can be renamed: help uses the current invocation name, and certificate discovery uses the script's containing directory, not the current working directory. Invoke it directly rather than through a symbolic link so it finds the intended `certs` directory. No environment configuration or ownership-marker files are generated.

Operational runs report the detected OS before checking distribution-specific prerequisites. Help, status messages, errors, and displayed trust-updater output wrap at 78 columns to fit an 80-column consoles. Certificate bytes are not wrapped. Help does not require OS detection.

Preview checks prerequisites and certificate paths, parses input certificates, and reports the installation plan or matching removal sources. Neither action inspects environment files, Java options, or systemd. Preview never creates temporary files, changes trust or configuration, or invokes the trust updater. It does not prove write permissions or successful application integration.

With `--apply`, installation copies certificate bytes unchanged and invokes `update-ca-certificates` on Debian-family systems or `update-ca-trust extract` on RHEL-family systems. Existing anchors with matching filenames are overwritten, so choose names carefully; the plan identifies those destination collisions. Previously installed certificates absent from `certs` are not automatically removed.

## Certificate Details

Certificate installation and removal show the same certificate fields in preview and apply modes. Installation includes each input's source and full destination path. Removal identifies each selected input (which is kept) and reports matching installed paths separately. Both show:

- Subject and issuer.
- Validity dates (`notBefore` and `notAfter`).
- SHA-256 certificate thumbprint, shown as 64 hexadecimal digits under its own label.
- Subject Key Identifier and Authority Key Identifier, or `not present` when absent.

The system CA bundle path and trust-update command are also displayed. In apply mode, each successful copy reports its installed destination, and the final installation trust-update summary repeats the bundle path. Removal shows details even when no installed match is found; only matching trust-store files are changed, and actual removals report their paths after changes. All user-facing output stays within 78 columns, including long names and paths.

Thumbprints come from decoded X.509 data, not a file checksum. Metadata before the PEM header does not affect identity and is preserved when the file is copied. Certificate parsing and metadata reporting happen before writes, but they do not prove that the CA is appropriate to trust or that an application uses the resulting bundle.

## Removal Actions

`--removecerts` previews matching certificates without inspecting or changing environment configuration. Add `--apply` to remove those matches and rebuild trust.

Certificate removal uses `certs/*.crt` as the removal list, not as files to delete. It compares SHA-256 thumbprints of decoded X.509 certificate data, not file hashes or filenames. Metadata before the PEM header, PEM formatting, and line endings do not affect certificate identity. The input directory is left unchanged.

Matching certificates are removed regardless of installer or ownership, including pre-existing and vendor-provided certificates in these source directories:

| Family        | Local Sources                        | Vendor Sources                             |
| ------------- | ------------------------------------ | ------------------------------------------ |
| Debian/Ubuntu | `/usr/local/share/ca-certificates` | `/usr/share/ca-certificates`             |
| RHEL/Fedora   | `/etc/pki/ca-trust/source/anchors` | `/usr/share/pki/ca-trust-source/anchors` |

Files are scanned recursively regardless of extension. PEM, trusted PEM, and single-certificate DER sources are supported. Mixed PEM files retain unrelated certificates and other PEM blocks. A source containing only selected certificates and surrounding metadata is deleted. Directory symlinks are not traversed; matching file symlinks are removed or replaced locally without modifying their external targets. Inputs must be outside these source directories.

When certificate removal is executed with `--apply`, the script rebuilds trust with `update-ca-certificates --fresh` or `update-ca-trust extract`. It checks the resulting system PEM bundle and returns an error if selected certificates remain trusted through another source. Generated bundles are never edited directly. No persistent state or backup directory is created; temporary replacement files are cleaned up on exit.

This is removal, not restoration of historical state. It cannot restore overwritten certificates. Package updates can reinstall vendor certificates. Private application stores, separately maintained Java stores, and p11-kit policy files are not scanned. If a selected certificate remains in the rebuilt bundle, inspect those other trust-policy sources. Failures after source files have changed are not automatically rolled back; resolve the reported problem and rerun `--removecerts --apply` to finish cleanup.


## Manual Client Trust Configuration

This section is documentation only; the script never performs these steps. For VM preparation, install the CA into system trust first, then test the intended application without overrides. Add a variable only when that runtime does not already use the updated trust store. Distribution packages, separately downloaded runtimes, Python virtual environments, and containers can have different defaults.

### PEM Bundles and Java Trust Stores

| Family            | System PEM CA bundle                   | Typical OS-generated Java trust store |
| ----------------- | -------------------------------------- | ------------------------------------- |
| Debian/Ubuntu     | `/etc/ssl/certs/ca-certificates.crt` | `/etc/ssl/certs/java/cacerts`       |
| RHEL/Rocky/Fedora | `/etc/pki/tls/certs/ca-bundle.crt`   | `/etc/pki/java/cacerts`             |

A PEM bundle is a text collection of certificates. Java's default JSSE trust manager normally reads a Java-format trust store such as JKS or PKCS12 instead, not a PEM bundle. Do not point `javax.net.ssl.trustStore` at the `.crt` bundle or assume renaming a PEM file converts it.

The Java paths above depend on installed distribution integration. Debian/Ubuntu normally use `ca-certificates-java`; RHEL-family distributions provide shared system trust integration. The distribution trust updater can refresh Java stores through its own integration, but this script neither installs that integration nor requires Java. Verify the actual JDK's trust store before adding an override: distribution OpenJDK may already use the generated store, while a downloaded JDK can have a separate `cacerts` file.

### Variables and Usage Scenarios

| Variable or option                                                  | Value                                             | When it is useful and what to consider                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CURL_CA_BUNDLE`                                                  | Absolute PEM bundle path                          | Usually unnecessary for distribution curl, which already uses system trust. Use only if that curl build selects a different CA file. This is a curl CLI setting; arbitrary libcurl applications need not honor it. See [curl TLS verification](https://curl.se/docs/sslcerts.html).                                                                                                                                                                                                                                                                                                                |
| `REQUESTS_CA_BUNDLE`                                              | Absolute PEM bundle path                          | Standard pip-installed Requests normally uses certifi, which can miss local system CAs. Some distribution packages already redirect certifi to system trust. This overrides Requests' CA selection when environment settings are honored. See [Requests verification](https://requests.readthedocs.io/en/latest/user/advanced/#ssl-cert-verification) and [CA defaults](https://requests.readthedocs.io/en/latest/user/advanced/#ca-certificates).                                                                                                                                                  |
| `SSL_CERT_FILE`                                                   | Absolute PEM bundle path                          | Useful for HTTPX, which normally uses certifi but honors this variable, or OpenSSL clients with different default paths. Often redundant for OS-integrated OpenSSL clients. It is not a universal substitute for `REQUESTS_CA_BUNDLE`. See [HTTPX SSL](https://www.python-httpx.org/advanced/ssl/) and [environment variables](https://www.python-httpx.org/environment_variables/#ssl_cert_file).                                                                                                                                                                                                |
| `NODE_EXTRA_CA_CERTS`                                             | Absolute PEM bundle path                          | Adds certificates when Node uses its bundled CA set. Unnecessary if Node already loads system trust. Read only at process startup; explicit TLS `ca` options bypass this default. See [Node extra CA certificates](https://nodejs.org/api/cli.html#node_extra_ca_certsfile).                                                                                                                                                                                                                                                                                                                     |
| `NODE_USE_SYSTEM_CA`                                              | `1`, not a path                                 | On supporting Node versions, enables system trust alongside bundled CAs. Consider it instead of an extra-bundle setting when system-store integration is available; check the deployed version. See [Node system CA support](https://nodejs.org/api/cli.html#node_use_system_ca1).                                                                                                                                                                                                                                                                                                                 |
| `JAVA_TOOL_OPTIONS` containing `-Djavax.net.ssl.trustStore=...` | Absolute Java-format trust-store path after `=` | Only for a JVM that is not already using the required OS-integrated Java store. Overrides the default store rather than adding to it, and can affect every JVM that inherits it. Preserve unrelated JVM options and avoid duplicate or conflicting trust-store options. Prefer an application-specific launcher or service configuration. See [JSSE trust-store selection](https://docs.oracle.com/en/java/javase/21/security/java-secure-socket-extension-jsse-reference-guide.html) and [JAVA_TOOL_OPTIONS](https://docs.oracle.com/javase/8/docs/technotes/guides/troubleshoot/envvars002.html). |

Requests can also use `CURL_CA_BUNDLE` as a fallback, but prefer its explicit `REQUESTS_CA_BUNDLE` setting when needed. Requests' prepared-request flow may need explicit environment merging; HTTPX can disable these variables with `trust_env=False`. Applications can supply their own TLS configuration and ignore these defaults entirely.

File-selection overrides can replace client-specific trust. Use the complete updated system bundle when that is the intended policy, not just a file containing one private root, which could break public-site verification. Other trust sources depend on the TLS backend. Node's extra CA option is additive; it is not an exact mirror of OS distrust policy. Do not use disabled TLS verification as a workaround.

### Choose the Narrowest Scope

For application-specific needs, prefer a one-command override or the application's launcher/service configuration. Use system-wide login settings only when the policy should apply to all relevant users. The examples below use Rocky/RHEL paths; substitute the Debian/Ubuntu paths from the table where appropriate. Choose only the variables needed by the application, not every row in the table.

#### One Command or Application

An environment prefix affects only that command and its children, not persistent system settings. Replace `your-command` with the intended program:

```bash
env REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt your-command
```

For Java, an application-specific JVM option is preferable to a global environment change:

```bash
java -Djavax.net.ssl.trustStore=/etc/pki/java/cacerts -jar your-app.jar
```

When the launcher cannot be edited, the equivalent variable value is `JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/etc/pki/java/cacerts"`. Do not replace an existing `JAVA_TOOL_OPTIONS` value blindly: merge the required option while retaining unrelated options and resolving existing trust-store settings. JSSE otherwise checks `jssecacerts` before `cacerts` under the active Java home; explicit application trust managers may behave differently.

#### Systemd Services

For a system service, prefer a per-service drop-in, not shell profiles or a manager-wide setting. Use `sudo systemctl edit "{service}.service"`, replacing `{service}` with the actual unit name, and add only the required setting under `[Service]`:

```ini
[Service]
Environment="REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt"
```

For a Java service that needs the override, the analogous entry is `Environment="JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=/etc/pki/java/cacerts"`, after accounting for existing JVM options. These are examples to choose between, not a recommendation to set both for every service.

Alternatively, reference a root-managed environment file from the service drop-in:

```ini
[Service]
EnvironmentFile=/etc/{service}/ca.env
```

That file contains plain assignments such as `REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt`. Neither `Environment=` nor `EnvironmentFile=` runs shell code; do not use `export`, command substitution, or `$OTHER_VARIABLE` expansion. An `EnvironmentFile` must exist unless explicitly configured as optional. Its assignments override `Environment=` values for the same keys.

Reload unit configuration with `sudo systemctl daemon-reload` and schedule `sudo systemctl restart "{service}.service"` when interruption is acceptable. A daemon reload alone does not change a running process's environment. The bundle path must also be readable inside any service sandbox or container.

See [systemd execution environments](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Environment=). Avoid global `DefaultEnvironment=` in `/etc/systemd/system.conf.d/` unless the settings truly belong in all system services; it is a separate mechanism from a service drop-in and can affect unrelated programs. See [systemd manager configuration](https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html#DefaultEnvironment=).

#### System-Wide Login Settings: /etc/environment

Use `/etc/environment` for simple, administrator-managed defaults for login sessions whose PAM stack reads it through `pam_env`. It is not a shell script and is not automatically inherited by every service on the machine. Preserve unrelated entries and add only needed literal assignments, for example:

```text
REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt
SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
```

Use absolute paths and plain `KEY=VALUE` lines. Do not put shell logic, `export`, `$HOME`, or references to another variable in these values. Configure the file as root-owned and not writable by ordinary users; mode `0644` is typical for non-secret paths. Do not store passwords or private keys in environment variables.

Start a new login session after editing. Applications inherit the session's environment only if their launch path preserves it; sudo, cron, GUI sessions, and service managers can apply different rules. Consult the local PAM configuration rather than assuming this file affects everything. Reference: [Linux-PAM pam_env manual](https://man7.org/linux/man-pages/man8/pam_env.8.html).

#### System-Wide Shell Defaults: /etc/profile.d/*.sh

On Debian/Ubuntu and RHEL-family systems, `/etc/profile` normally sources `.sh` snippets in `/etc/profile.d/`. Use a root-owned, readable file such as `/etc/profile.d/{scriptname}.sh` for shell-login defaults, particularly when conditional logic is needed. It is sourced, so it normally needs mode `0644`, not an executable bit. Use POSIX-compatible shell syntax and never make it writable by ordinary users.

For example, set a Requests default only when it is not already set, preserving an explicit existing value:

```sh
if [ "${REQUESTS_CA_BUNDLE+x}" != x ]; then
	export REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt
fi
```

Use analogous assignments only for other clients that need them. Non-login shells, non-shell applications, systemd services, scheduled jobs, and containers do not universally read these files. Existing sessions are not changed; start a new login shell or deliberately source the reviewed snippet for the current shell. Prefer a user's own login profile instead when only that user needs the setting.

Choose either a PAM environment default or a shell-profile default for a given login policy instead of duplicating conflicting assignments in both. The `/etc/profile.d/` inclusion is a distribution convention, so inspect `/etc/profile` on the target VM. Reference: [Bash startup files](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html).

### Existing Configuration from Older Versions

This version does not discover or clean up environment settings created by older versions. Those versions may have written `/etc/environment`, `/etc/profile.d/{scriptname}.sh`, and `/etc/systemd/system.conf.d/{scriptname}.conf` using the script name at that time.

Review and back up those files manually before editing. Remove only obsolete assignments or files whose contents you have confirmed were dedicated to this setup; preserve custom paths, unrelated settings, and other `JAVA_TOOL_OPTIONS` arguments. Do not delete all profile or systemd files based on a broad filename pattern. New sessions are needed to drop inherited login variables. If an old systemd manager `DefaultEnvironment=` drop-in was activated, schedule a manager reexecution (`systemctl daemon-reexec`) and affected service restarts, or a reboot, as appropriate; a unit-only `daemon-reload` is not a substitute. The script performs none of these actions.

### Additional References

- [RHEL shared system certificates](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/securing_networks/using-shared-system-certificates_securing-networks): centralized trust and distribution integration, including Java.
- [Debian update-ca-certificates manual](https://manpages.debian.org/stable/ca-certificates/update-ca-certificates.8.en.html): generated PEM bundle and update hooks.
- [Python SSL default trust paths](https://docs.python.org/3/library/ssl.html#ssl.get_default_verify_paths): distinguish standard-library/OpenSSL defaults from a third-party library's bundled CAs.
- [Node system CA loading](https://nodejs.org/api/cli.html#--use-system-ca): how system trust is combined with bundled and extra certificates.
