# Configure Proxy

This [configure-proxy.sh](./configure-proxy.sh) script is a human-tested, vibe-coded script to manage explicit HTTP/HTTPS proxy environment settings for Linux login environments, sudo, and selected systemd services. It can also remove the selected settings.

**Configuration and removal preview by default, even when running as root.
Nothing is applied unless you supply `--apply`.**

The script writes both lowercase and uppercase versions of these variables:

```text
http_proxy   https_proxy   no_proxy
HTTP_PROXY   HTTPS_PROXY   NO_PROXY
```

## Requirements

- Linux with Bash, `awk`, `diff`, and standard GNU/Linux utilities, including
  `cat`, `dirname`, `install`, `mktemp`, `chmod`, `chown`, `mv`, and `rm`.
- Root privileges for actual configuration changes or removal. Examples use
  `sudo`; the script does not elevate itself.
- `visudo` when applying sudoers configuration. Sudoers preview and removal do
  not require it.
- `systemctl` and inspectable service units for systemd targets. If these are
  unavailable, those targets warn and skip; other targets can still proceed.

Input validation uses Bash only. No Python, Node.js, or other language runtime
is required, and no packages are installed automatically.

Invoke it with Bash, not `sh`, and do not source it into your shell.

## Quick Start

Run commands from the directory containing the script. Display built-in help:

```bash
bash ./configure-proxy.sh --help
```

Preview configuration for the login environment and shell profile:

```bash
bash ./configure-proxy.sh --environment --profile \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,.example.local'
```

Review the displayed paths and diffs, then apply the same configuration:

```bash
sudo bash ./configure-proxy.sh --environment --profile \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,.example.local' \
  --apply
```

Replace the example proxy and bypass list with your own values. Preview may
also require `sudo` to read existing protected files, particularly sudoers
fragments. **Using `sudo` alone does not enable writes.**

## Target Selection

Select at least one target. Targets can be combined independently.

`NAME` below defaults to `90-explicit-proxy` and can be changed with
`--dropin-name`.

| Option             | Target and behavior                                                                                                                                                    |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--environment`  | Manage the six proxy assignments in `/etc/environment`, retaining unrelated lines.                                                                                   |
| `--profile`      | Write `/etc/profile.d/NAME.sh`, exporting all six variables.                                                                                                         |
| `--sudoers`      | Write `/etc/sudoers.d/NAME`, adding the six variable names to `Defaults env_keep`. This fragment preserves variables through sudo; it does not store their values. |
| `--waagent`      | Select `waagent.service` and write `/etc/systemd/system/waagent.service.d/NAME.conf` if the unit is available.                                                     |
| `--daemons LIST` | Select comma-separated `.service` unit names. Each available unit gets `/etc/systemd/system/<unit>.d/NAME.conf`.                                                   |
| `--alldefaults`  | Select environment, profile, sudoers, and waagent. It does not discover other services.                                                                                |

Use complete service unit names, such as `myapp.service`, rather than process
names or wildcard patterns. `--daemons` may be repeated, and duplicate selections
are processed only once.

### Service Availability

All service selections use `systemctl show` and require `LoadState=loaded`.
The service does not have to be running. This is a service availability check,
not an Azure VM check; no IMDS or other network request is made.

Missing or masked units, failed inspection, and missing `systemctl` produce
warnings and skip the affected service without blocking other targets.
Skipped services receive no file changes or restarts, including during removal.
An existing drop-in for an unavailable service is therefore left untouched.

If every requested target is skipped and no other targets remain, the script
reports `No applicable targets; no changes made.` and exits successfully without
requiring root.

## Values and Action Options

For configuration, supply all three proxy-value options explicitly, even when
selecting only sudoers. Removal must not include these three options.

| Option                 | Meaning                                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `--http_proxy URL`   | Proxy URL for HTTP traffic.                                                                        |
| `--https_proxy URL`  | Proxy URL for HTTPS traffic. It can point to an HTTP proxy, as in the examples.                    |
| `--no_proxy LIST`    | Comma-separated bypass entries. Use `--no_proxy ''` for an explicitly empty list.                |
| `--dropin-name NAME` | Shared basename for profile, sudoers, and systemd files. Default: `90-explicit-proxy`.           |
| `--apply`            | Perform the selected configuration or removal instead of previewing.                               |
| `--remove`           | Select removal. Without `--apply`, only show the removal plan.                                   |
| `--restartdaemons`   | Restart available selected services after apply/removal. Requires `--apply` and a daemon target. |
| `--help`             | Display usage without requiring targets or proxy values.                                           |

### Accepted Proxy and Bypass Values

Proxy URLs must be ASCII `http://host[:port]` or `https://host[:port]` values:

- Hostnames, IPv4 addresses, and bracketed IPv6 addresses are supported.
- Ports, when supplied, must be between 1 and 65535.
- Credentials, paths, trailing slashes, queries, and fragments are rejected.
- Example IPv6 proxy: `http://[2001:db8::10]:8080`.

The bypass list accepts entries such as:

- Hostnames and suffixes: `localhost`, `app.example.local`, `.example.local`.
- Addresses: `192.0.2.10`, `2001:db8::10`.
- CIDRs: `192.0.2.0/24`, `2001:db8::/32`.
- Host/address ports: `app.example.local:8443`, `192.0.2.10:8443`, `[::1]:443`.
- `*`, but only as the entire list.

Do not put whitespace or empty entries between commas. An entirely empty list
is allowed. Bypass matching, especially CIDR support, varies between clients;
acceptance by this script does not guarantee every application interprets a
value identically.

### Custom Filenames

Supply a basename without an extension or directory:

```text
--dropin-name 80-company-proxy
```

This selects:

- `/etc/profile.d/80-company-proxy.sh`
- `/etc/sudoers.d/80-company-proxy`
- `/etc/systemd/system/<unit>.d/80-company-proxy.conf`

Previews show the resolved full paths for each applicable target.
`/etc/environment` is fixed and is not renamed by this option.

Names must contain 1-250 ASCII letters, digits, underscores, or hyphens and
start with a letter or digit. Dots are excluded because sudoers ignores
filenames containing them.

Changing the basename does not rename, migrate, or remove files created under
another name. Use the original name when removing those files. Different named
fragments can coexist, so review their combined effect.

## More Examples

These are independent scenarios, not a sequence to run in full.

### Preview All Defaults and Additional Services

```bash
bash ./configure-proxy.sh --alldefaults \
  --daemons myapp.service,worker.service \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,169.254.169.254,168.63.129.16,.example.local'
```

The bypass list is illustrative, including Azure platform addresses where
appropriate; the script does not add bypass entries automatically. Replace the
service names with your actual units. Missing services only warn and skip.

### Preview a Custom Basename

```bash
bash ./configure-proxy.sh --alldefaults --daemons myapp.service \
  --dropin-name 80-company-proxy \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,.example.local'
```

After reviewing the preview, run the same command as root with `--apply` to
write those files.

### Apply Service Configuration and Explicitly Restart

Preview first by omitting both `--apply` and `--restartdaemons`. After review:

```bash
sudo bash ./configure-proxy.sh --daemons myapp.service,worker.service \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,.example.local' \
  --apply --restartdaemons
```

Only the selected available services are restarted. This also restarts services
whose drop-ins were already identical, and can start previously stopped services.

## Removal

Use the same targets and basename that identify the configuration to remove.
Do not pass proxy URLs or a bypass list.

Preview removal of custom-named files and the environment assignments:

```bash
bash ./configure-proxy.sh --alldefaults --daemons myapp.service \
  --dropin-name 80-company-proxy --remove
```

Apply the reviewed removal:

```bash
sudo bash ./configure-proxy.sh --alldefaults --daemons myapp.service \
  --dropin-name 80-company-proxy --remove --apply
```

Omit `--dropin-name` to target the default `90-explicit-proxy` basename. Add
`--restartdaemons` to an applied removal if you also want the selected available
services restarted.

Removal behavior:

- `/etc/environment`: remove all six proxy assignments, including assignments
  that existed before this script ran. Keep unrelated lines.
- Named files: remove only the selected filenames, and only when their first
  line is exactly `# Managed by configure-proxy.sh`.
- Missing files are reported as unchanged.
- Other names, unselected targets, and unavailable service drop-ins are left
  untouched.
- Removal does not restore overwritten values or historical configuration.

## File Updates and Activation

- Each processed target shows its full path and a diff. Preview changes no
  configuration files and performs no service reloads or restarts.
- Identical file contents are left unchanged on repeated runs. Explicit service
  restarts remain an exception: they still run when requested.
- Named files are replaced in full during configuration, including a colliding
  file not created by this script. The managed-file header is required for
  removal, not for replacement during apply.
- Target files that are symlinks or non-regular files are refused. Existing files
  must be readable.
- Replacements use a temporary file in the target directory followed by a move.
  Sudoers content is checked with `visudo` before replacement.
- An existing environment file keeps its mode and ownership. New environment,
  profile, and systemd files use mode `0644`; sudoers fragments use `0440`.
  Newly created targets and named-file replacements are owned by root.
- After successful processing, changed systemd drop-ins trigger
  `systemctl daemon-reload`. This alone does not restart services or change
  their running environments.
- Login/profile changes take effect through the normal session lifecycle; the
  script does not update the calling shell's environment. Applications and
  services must support the configured proxy variables.

**Batches are not transactions.** An error can leave earlier files changed or
earlier services restarted. There is no automatic backup or rollback.
Reload/restart failures do not undo written files.

Invalid arguments, insufficient permissions, and failed file operations cause
a nonzero exit. Warnings about skipped services alone do not fail the run, so
review the output rather than treating exit status zero as proof that every
requested service was configured.

## Tests and Development Checks

The tests are development tools, not prerequisites for using the script:

- [test-validation.sh](./tests/test-validation.sh) checks input validation,
  preview output, and operation without Python.
- [test-removal.sh](./tests/test-removal.sh) checks preview/apply, removal,
  service availability, restarts, and custom filenames using temporary files
  and mocked privileges/services.

Run from this directory in Linux Bash:

```bash
bash -n ./configure-proxy.sh
bash -n ./tests/test-validation.sh
bash -n ./tests/test-removal.sh
bash ./tests/test-validation.sh
bash ./tests/test-removal.sh
```

Run a single case or a case-name glob:

```bash
bash ./tests/test-validation.sh 'IPv6 compressed proxy'
bash ./tests/test-removal.sh 'named daemons skip unavailable unit: not-found'
```

If ShellCheck is installed:

```bash
shellcheck ./configure-proxy.sh ./tests/test-validation.sh ./tests/test-removal.sh
```

The tests clean up their temporary files and do not modify live configuration
or restart real services. They do not establish real systemd integration,
sudoers syntax validity, or root ownership. See [AGENTS.md](./AGENTS.md) for
contributor guidance and WSL validation commands.
