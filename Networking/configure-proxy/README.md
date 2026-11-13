# Configure Proxy

This [configure-proxy.sh](./configure-proxy.sh) script is a human-tested, vibe-coded script to manage explicit HTTP/HTTPS proxy environment settings for Linux login environments, sudo, selected systemd services, and opt-in system-manager defaults. It can also remove the selected settings.

It is designed to be distro-agnostic across modern, supported Linux distributions. Behavior follows available tools and native unit/manager interfaces, not distro names or a fixed systemd release. Individual VM tests are evidence, not a compatibility guarantee for every image; see [Known Issues](#known-issues).

**Configuration and removal preview by default, even when running as root. Nothing is applied unless you supply `--apply`.**

The script writes both lowercase and uppercase versions of these variables:

```text
http_proxy   https_proxy   no_proxy
HTTP_PROXY   HTTPS_PROXY   NO_PROXY
```

## Requirements

- Linux with Bash, `awk`, `diff`, and standard GNU/Linux utilities, including `cat`, `dirname`, `install`, `mktemp`, `chmod`, `chown`, `mv`, and `rm`.
- Root privileges for actual configuration changes or removal. Examples use `sudo`; the script does not elevate itself.
- `visudo` when applying sudoers configuration. Sudoers preview and removal do not require it.
- `systemctl` and inspectable service units for per-service targets, or an inspectable system manager for `--systemd-manager`. Unavailable targets warn and skip; other targets can still proceed.

Input validation uses Bash only. No Python, Node.js, or other language runtime is required, and no packages are installed automatically.

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
  --no_proxy 'localhost,127.0.0.1,::1,example.local'
```

Review the displayed paths and diffs, then apply the same configuration with `--apply`:

```bash
sudo bash ./configure-proxy.sh --environment --profile \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local' \
  --apply
```

Replace the example proxy and bypass list with your own values. Preview may also require `sudo` to read existing protected files, particularly sudoers fragments. **Using `sudo` alone does not enable writes.**

## Target Selection

Select at least one target. Targets can be combined independently.

`NAME` below defaults to `90-explicit-proxy` and can be changed with `--dropin-name`.

| Option                | Target and behavior                                                                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--environment`     | Manage the six proxy assignments in `/etc/environment`, retaining unrelated lines.                                                                                      |
| `--profile`         | Write `/etc/profile.d/NAME.sh`, exporting all six variables.                                                                                                            |
| `--sudoers`         | Write `/etc/sudoers.d/NAME`, adding the six variable names to `Defaults env_keep`. This fragment preserves variables through sudo; it does not store their values.    |
| `--waagent`         | Resolve `waagent.service` or `walinuxagent.service` and write `/etc/systemd/system/<selected-agent-unit>.d/NAME.conf` when an unambiguous available agent is found. |
| `--daemons LIST`    | Select comma-separated `.service` unit names. Each available unit gets `/etc/systemd/system/<unit>.d/NAME.conf`.                                                      |
| `--alldefaults`     | Select environment, profile, sudoers, and waagent. It does not discover other services.                                                                                   |
| `--systemd-manager` | Write `/etc/systemd/system.conf.d/NAME.conf` with proxy defaults for newly started system services. Explicit opt-in; not included in `--alldefaults`.                 |

Use complete service unit names, such as `myapp.service`, rather than process names or wildcard patterns. `--daemons` may be repeated, and repeated identical unit names are processed only once.

### Scope and Activation

These targets affect different processes and are not interchangeable:

| Target                                                  | Which processes it affects                                                                                                                                                                                  | When updated settings take effect                                                                                                                                        |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--environment`: `/etc/environment`                 | Sessions whose startup configuration loads this file, typically through PAM, and applications launched from those sessions. It is not a shell script or a universal configuration source for every process. | New applicable login sessions. Existing sessions retain their previous environment.                                                                                      |
| `--profile`: `/etc/profile.d/NAME.sh`               | Shells whose startup files source these scripts, typically login shells, and commands started from those shells. Not every non-login shell reads them.                                                      | Start a new applicable shell, or explicitly source the generated profile fragment in the current shell. This affects subsequent commands, not already-running processes. |
| `--sudoers`: `/etc/sudoers.d/NAME`                  | Commands launched through sudo: `env_keep` allows existing proxy variables from the caller to be retained, subject to the overall sudo policy. **It does not define proxy values.**                 | Subsequent sudo invocations; no service restart is needed. The caller must already have the variables in its environment.                                                |
| `--waagent` / `--daemons`: systemd service drop-ins | Only the selected systemd system services and their child processes, not interactive user sessions.                                                                                                         | After `systemctl daemon-reload`, when the service starts or restarts. Already-running services keep their previous environment until restarted.                        |
| `--systemd-manager`: system-manager drop-in           | Defaults for newly started system-service processes and their descendants, including services not named in the command. Per-service settings can override these defaults.                                   | After `daemon-reload`, on subsequent service starts/restarts. Running processes are not updated, and services are not restarted automatically.                         |

**Login environment settings do not automatically configure systemd system services.** Use per-service drop-ins or explicitly selected manager defaults rather than relying on `/etc/environment` or shell profiles.

The script reloads systemd when drop-ins change. To also restart the selected available services, use `--apply --restartdaemons`; `daemon-reload` alone does not update their running processes.

### Service Availability

All service selections use `systemctl show` and require `LoadState=loaded`. The service does not have to be running. This is a service availability check, not an Azure VM check; no IMDS or other network request is made.

Missing or masked units, failed inspection, and missing `systemctl` produce warnings and skip the affected service without blocking other targets. Skipped services receive no file changes or restarts, including during removal. An existing drop-in for an unavailable service is therefore left untouched.

If every requested target is skipped and no other targets remain, the script reports `No applicable targets; no changes made.` and exits successfully without requiring root.

### Azure Linux Agent Discovery

`--waagent`, including its use through `--alldefaults`, checks the two known unit names without inferring which distribution is installed:

| Available agent units                                  | Automatic selection                                                                                                                                        |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Only `waagent.service`                               | Use `waagent.service`.                                                                                                                                   |
| Only `walinuxagent.service`                          | Use `walinuxagent.service`.                                                                                                                              |
| Both names are aliases of the same systemd unit `Id` | Use one automatic target. Prefer an explicit matching `--daemons` selection; otherwise retain `waagent.service` for compatibility with existing paths. |
| Both names identify different available units          | Warn and skip automatic agent selection; select the intended unit explicitly with `--daemons`.                                                           |
| Neither is available, or required identity checks fail | Warn and skip the automatic target while other applicable targets continue.                                                                                |

The service need not be running: availability still means `LoadState=loaded`. Failed or empty probe results remain visible as warnings; a confirmed available alternative can still be used when the other availability probe fails. Explicit `--daemons` selections remain independent, including when automatic selection is ambiguous.

The resolved unit appears in the preview path and is used for the requested file changes and restarts. Discovery does not migrate or remove files under other unit names. See [agent service names and future renames](#agent-service-names-and-future-renames) for the manual-name workaround.

### System-Manager Defaults

Use `--systemd-manager` when the VM has a deliberate common proxy policy for systemd-started services. Prefer per-service `--daemons` or `--waagent` drop-ins when only a few services need a proxy, or when their settings differ.

The manager target writes six `DefaultEnvironment=` assignments under `[Manager]` in the selected `system.conf.d` file. It does not write `ManagerEnvironment=`, which configures the manager process's own environment rather than the defaults passed to system services. It does not edit the main `system.conf`, reset the entire default environment, or manage per-user `user.conf` files.

Manager defaults have a broad scope, including services installed or started later. Review bypass requirements carefully. They are defaults, not enforcement: later manager drop-ins can override the same variables, and per-unit `Environment=`, `EnvironmentFile=`, PAM-provided values, or `UnsetEnvironment=` can override or remove them. Applications must still support the proxy variables. See the [systemd environment precedence documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).

**`--alldefaults` deliberately excludes this target.** Combine it explicitly with other targets only when that broader scope is intended.

The script queries the system manager before processing this target. Missing `systemctl`, failed inspection, or an empty manager response warns and skips it. Existing manager files are left untouched when the target is skipped, including during removal. The manager's `Version` response is treated as opaque availability information, not a version requirement or compatibility certification.

Changed manager drop-ins use the same `systemctl daemon-reload` step as changed service drop-ins. Verify the effective manager environment on the actual build, particularly after removal; see [manager-default removal on older builds](#manager-default-removal-on-older-builds). The script does not invoke `daemon-reexec`, clear the manager environment, or reboot automatically.

Running processes retain their previous environment until restarted. `--systemd-manager` alone does not permit `--restartdaemons`: select services through `--daemons`, `--waagent`, or `--alldefaults` if the script should restart them. Those selectors also manage their per-service drop-ins. If you want only manager defaults without per-service overrides, restart chosen services separately after applying.

This read-only command displays the manager's environment for future service starts:

```bash
systemctl show-environment
```

It does not prove that an already-running service received the values, or that a service-specific override does not take precedence. Verify the actual application on an authorized test VM.

## Values and Action Options

For configuration, supply all three proxy-value options explicitly, even when selecting only sudoers. Removal must not include these three options.

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

- Hostnames and suffixes: `localhost`, `app.example.local`, `.example.local`, `local`.
- Addresses: `192.0.2.10`, `2001:db8::10`.
- CIDRs: `192.0.2.0/24`, `2001:db8::/32`.
- Host/address ports: `app.example.local:8443`, `192.0.2.10:8443`, `[::1]:443`.
- `*`, but only as the entire list.

Leading-dot handling in `no_proxy` varies between clients. To bypass a domain itself and its subdomains, prefer an entry without a leading dot, such as `example.local` rather than `.example.local`. Some clients, including Go's proxy matcher, treat the dotted form as subdomains-only: it matches `app.example.local`, but not `example.local`. Others, such as curl, ignore the leading dot. This distinction is not determined by the number of DNS labels. See [GitLab&#39;s leading-dot example](https://about.gitlab.com/blog/we-need-to-talk-no-proxy/#the-impact-of-leading-dots-in-no_proxy) and [Go&#39;s proxy-matching reference](https://pkg.go.dev/golang.org/x/net/http/httpproxy#Config), and verify the behavior of the clients used by your applications.

For the `local` suffix, both `local` and `.local` can match hosts such as `server.local`; in clients with subdomain-only leading-dot semantics, using `local` also includes the literal hostname `local`.

Do not put whitespace or empty entries between commas. An entirely empty list is allowed. Bypass matching, especially CIDR support, varies between clients; acceptance by this script does not guarantee every application interprets a value identically.

Literal `%` characters are written as `%%` in generated systemd files to prevent specifier expansion. This preserves the original value for service processes, including IPv6 scope identifiers; environment/profile values are not doubled.

### Custom Filenames

Supply a basename without an extension or directory:

```text
--dropin-name 80-company-proxy
```

This selects:

- `/etc/profile.d/80-company-proxy.sh`
- `/etc/sudoers.d/80-company-proxy`
- `/etc/systemd/system/<unit>.d/80-company-proxy.conf`
- `/etc/systemd/system.conf.d/80-company-proxy.conf` when `--systemd-manager` is selected

Previews show the resolved full paths for each applicable target. `/etc/environment` is fixed and is not renamed by this option.

Names must contain 1-250 ASCII letters, digits, underscores, or hyphens and start with a letter or digit. Dots are excluded because sudoers ignores filenames containing them.

#### Filename Ordering

Filenames affect configuration loading and merging order, not the order in which systemd starts services. Systemd processes differently named [service drop-ins](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html) and [manager drop-ins](https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html#Configuration%20Directories%20and%20Precedence) in **lexicographic (filename) order**. Ordering is lexical, not numeric: a `90-` or `99-` prefix still sorts before an ordinary name such as `override.conf`. For example, applicable systemd drop-ins with these names are read in this order:

```text
90-explicit-proxy.conf
99-custom.conf
override.conf
zz-proxy-config.conf
```

When numbered and non-numbered filenames are mixed, `--dropin-name zz-proxy-config` can therefore help place your proxy fragment after both numbered files and names such as `override.conf`. The `zz-` prefix is a convention, not a guaranteed highest priority: a name such as `zzz-local.conf` can still sort later. Directory precedence and setting-specific merge rules also apply; for example, a later-named manager file cannot force its defaults over per-service environment settings.

The same basename also affects the other targets. [Sudoers includes are read in lexical order](https://www.sudo.ws/docs/man/sudoers.man/), while profile fragments are typically sourced in filename order, subject to the shell and startup configuration. Review the applicable files and their combined settings rather than assuming a prefix alone guarantees the final values.

Changing the basename does not rename, migrate, or remove files created under another name. Use the original name when removing those files. Different named fragments can coexist, so review their combined effect.

## More Examples

These are independent scenarios, not a sequence to run in full.

### Preview Profile or Sudoers Separately

Only the selected target is processed. Both are already included in `--alldefaults`, but neither requires the other:

```bash
bash ./configure-proxy.sh --profile \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local'
```

```bash
bash ./configure-proxy.sh --sudoers \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local'
```

The sudoers target still requires the three configuration values as CLI inputs, but its file contains variable-preservation rules, not those values.

### Preview All Defaults and Additional Services

```bash
bash ./configure-proxy.sh --alldefaults \
  --daemons myapp.service,worker.service \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,169.254.169.254,168.63.129.16,example.local'
```

The bypass list is illustrative, including Azure platform addresses where appropriate; the script does not add bypass entries automatically. Replace the service names with your actual units. Missing services only warn and skip.

### Preview a Custom Basename

```bash
bash ./configure-proxy.sh --alldefaults --daemons myapp.service \
  --dropin-name 80-company-proxy \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local'
```

After reviewing the preview, run the same command as root with `--apply` to write those files.

### Apply Service Configuration and Explicitly Restart

Preview first by omitting both `--apply` and `--restartdaemons`. After review:

```bash
sudo bash ./configure-proxy.sh --daemons myapp.service,worker.service \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local' \
  --apply --restartdaemons
```

Only the selected available services are restarted. This also restarts services whose drop-ins were already identical, and can start previously stopped services.

### Preview System-Manager Defaults

This is a broader alternative to selecting individual service drop-ins:

```bash
bash ./configure-proxy.sh --systemd-manager \
  --dropin-name zz-proxy-config \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,169.254.169.254,168.63.129.16,local'
```

The preview shows `/etc/systemd/system.conf.d/zz-proxy-config.conf` and its `DefaultEnvironment=` assignments. After reviewing the scope and diff, run the same command as root with `--apply`. The manager is reloaded when the file changes, but no services are restarted by this manager-only command.

## Removal

Use the same targets and basename that identify the configuration to remove. Do not pass proxy URLs or a bypass list.

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

Omit `--dropin-name` to target the default `90-explicit-proxy` basename. Add `--restartdaemons` to an applied removal if you also want the selected available services restarted.

To preview removal of only a manager drop-in, use its original basename:

```bash
bash ./configure-proxy.sh --systemd-manager \
  --dropin-name zz-proxy-config --remove
```

Then apply that reviewed removal:

```bash
sudo bash ./configure-proxy.sh --systemd-manager \
  --dropin-name zz-proxy-config --remove --apply
```

Only the selected managed file is removed. Other manager configuration remains, and variables supplied elsewhere can still take effect. Existing processes keep their inherited environment until restarted.

Removal behavior:

- `/etc/environment`: remove all six proxy assignments, including assignments that existed before this script ran. Keep unrelated lines.
- Named files: remove only the selected filenames, and only when their first line is exactly `# Managed by configure-proxy.sh`.
- Missing files are reported as unchanged.
- Other names, unselected targets, and unavailable systemd targets are left untouched.
- Removal does not restore overwritten values or historical configuration.

## File Updates and Activation

- Each processed target shows its full path and a diff. Preview changes no configuration files and performs no service reloads or restarts.
- Identical file contents are left unchanged on repeated runs. Explicit service restarts remain an exception: they still run when requested.
- Named files are replaced in full during configuration, including a colliding file not created by this script. The managed-file header is required for removal, not for replacement during apply.
- Target files that are symlinks or non-regular files are refused. Existing files must be readable.
- Replacements use a temporary file in the target directory followed by a move. Sudoers content is checked with `visudo` before replacement.
- An existing environment file keeps its mode and ownership. New environment, profile, and systemd files use mode `0644`; sudoers fragments use `0440`. Newly created targets and named-file replacements are owned by root.
- After successful processing, changed service or manager drop-ins trigger one `systemctl daemon-reload`. This alone does not restart services or change their running environments. The reload is announced before invoking systemd, and native warnings and failure statuses are retained.
- Login/profile changes follow the [scope and activation rules](#scope-and-activation). The script does not update the calling shell's environment. Applications and services must support the configured proxy variables.

**Batches are not transactions.** An error can leave earlier files changed or earlier services restarted. There is no automatic backup or rollback. Reload/restart failures do not undo written files.

Invalid arguments, insufficient permissions, and failed file operations cause a nonzero exit. Warnings about skipped services alone do not fail the run, so review the output rather than treating exit status zero as proof that every requested service was configured.

## Known Issues

### rc-local Generator Warning

You may see a message such as:

```text
systemd-rc-local-generator: /etc/rc.local is not marked executable, skipping.
```

`systemctl daemon-reload` reruns systemd generators, even when only one service's drop-in changed. The rc-local compatibility generator checks whether the legacy rc.local script is executable. This warning means that rc.local was skipped; it does not mean waagent or the proxy drop-in was rejected.

The rc.local path depends on how the distribution builds systemd; it might be `/etc/rc.local`, `/etc/rc.d/rc.local`, or another configured path. [Generators can log through the kernel/console](https://www.freedesktop.org/software/systemd/man/latest/systemd.generator.html), so the message is not necessarily ordinary output from the proxy script. See the [rc-local generator documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd-rc-local-generator.html).

Inspect the relevant state without changing it:

```bash
rc_local_path=/etc/rc.local  # Replace with the path printed in your warning.
stat -c '%A %a %n' "$rc_local_path"
journalctl -b --no-pager --grep='rc[.]local'
```

Use `systemctl --no-pager status <unit>` with the actual selected unit when checking a service's result. Journal access may require elevated privileges.

A warning with a successful reload is not treated as a script failure. A failed reload remains fatal, leaves written files on disk, and prevents subsequent script-requested service restarts. Check exit status and the service result; the warning alone proves neither failure nor success of the proxy configuration.

Do not make rc.local executable merely to silence the warning: that can enable legacy boot commands. This script does not modify rc.local, mask its generator, or suppress systemd diagnostics.

### Agent Service Names and Future Renames

Automatic discovery recognizes `waagent.service` and `walinuxagent.service`. If an installation uses another name, or both known names identify different units, specify the intended name directly:

```bash
bash ./configure-proxy.sh --daemons actual-agent.service \
  --http_proxy http://proxy.example:8080 \
  --https_proxy http://proxy.example:8080 \
  --no_proxy 'localhost,127.0.0.1,::1,example.local'
```

Replace `actual-agent.service` with the installed unit name. Use `--daemons` in place of `--waagent`; to avoid the automatic lookup included in `--alldefaults`, select its other targets with `--environment --profile --sudoers` as needed. Unavailable explicitly named units still warn and skip.

Changing the unit name does not move previous drop-ins. Review the preview path and any existing overrides before applying; stale files under an old name are not automatically removed.

### Manager-Default Removal on Older Builds

Some older systemd builds may retain previously loaded manager defaults after the corresponding drop-in is removed and `daemon-reload` succeeds. An [older upstream reload implementation](https://github.com/systemd/systemd/blob/v239/src/core/main.c) and its [environment merge helper](https://github.com/systemd/systemd/blob/v239/src/core/manager.c) illustrate this behavior. These are historical examples, not a target version or minimum-version rule; vendor backports and other configuration sources matter.

After removal, inspect the manager's current environment:

```bash
systemctl show-environment
```

Also review other manager drop-ins and per-service environment settings before attributing retained values to this issue. A deleted file and a successful reload are not proof that the effective defaults were cleared.

This differs from the normal behavior of already-running processes retaining their environment: stale manager defaults can affect future service starts too. Verify a new process on an authorized test system when confirming the outcome.

The script does not automatically unset environment variables, reexecute the manager, or reboot to work around this issue. Those actions can affect unrelated configuration and require separate operator review and authorization.

### Minimal Images and Missing Prerequisites

A modern, supported distribution can still have a minimal image that lacks Bash, GNU utilities, `awk`, `diff`, `visudo`, systemd, or an accessible system bus. Command names alone may not be sufficient: limited replacements such as BusyBox tools might lack GNU options used by the script.

- Invoke the script with Bash, not `sh`.
- Missing or inaccessible systemd causes service/manager targets to warn and skip; non-systemd targets can still be used when their prerequisites are present.
- Applying `--sudoers` requires `visudo`, commonly supplied by the distro's sudo package. `--alldefaults` includes that target.
- Other missing utilities can stop processing. Because changes are sequential, inspect any earlier applied targets after a failure.

Install suitable distribution-provided packages if permitted, or omit targets whose prerequisites are unavailable. The script does not install packages, replace tools, or add language runtimes automatically.
