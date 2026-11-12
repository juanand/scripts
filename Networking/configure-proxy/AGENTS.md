# Configure Proxy

## Scope

- The [configure-proxy.sh](configure-proxy.sh) is a standalone Linux CLI to configure explicit proxy.
- It uses Bash-only input validation; do not introduce dependencies on runtimes like Python, Node, Ruby, etc. or sibling scripts.
- Its `usage()` text is the operator-facing documentation, along with README.md

## Validation

Run from this workspace directory using Linux Bash:

```bash
bash -n ./configure-proxy.sh
bash -n ./tests/test-validation.sh
bash -n ./tests/test-removal.sh
bash ./configure-proxy.sh --help
bash ./tests/test-validation.sh
bash ./tests/test-removal.sh
bash ./tests/test-validation.sh 'IPv6 compressed proxy'
bash ./tests/test-removal.sh 'removal preview at UID 0'
bash ./tests/test-removal.sh 'custom names appear in preview'
```

When ShellCheck is installed:

```bash
shellcheck ./configure-proxy.sh ./tests/test-validation.sh ./tests/test-removal.sh
```

On Windows with an existing WSL environment, the equivalent commands are:

```powershell
wsl.exe --exec bash -n configure-proxy.sh
wsl.exe --exec bash -n tests/test-validation.sh
wsl.exe --exec bash -n tests/test-removal.sh
wsl.exe --exec bash configure-proxy.sh --help
wsl.exe --exec bash tests/test-validation.sh
wsl.exe --exec bash tests/test-removal.sh
wsl.exe --exec shellcheck configure-proxy.sh tests/test-validation.sh tests/test-removal.sh
```

The ShellCheck command remains conditional on its availability inside WSL.
Use LF line endings for the Bash source; CRLF causes Linux/WSL syntax failures.
Do not source the script to load helpers: argument handling and target processing
execute at top level.

The [validation tests](tests/test-validation.sh) run previews with a restricted
PATH containing no Python or mutation utilities. A stub answers read-only
systemd queries for a nonexistent fixture service; no live configuration changes
or service operations are performed. The optional argument selects case names
using a Bash glob.

The [target/removal tests](tests/test-removal.sh) redirect system paths in a
private script copy and simulate the UID, ownership calls, sudoers validation,
and systemd operations. They exercise preview/apply against temporary files,
including daemon availability, custom filenames, and preservation of
unrelated settings. They do not validate real service integration, sudoers
syntax, or root ownership.

Live configuration writes or service restarts require an explicitly authorized
disposable Linux target. Do not use `--apply` or `--restartdaemons` against the
development host's configuration as validation.

## Execution flow

1. Parse explicit targets, values, and operation flags. Bash helpers validate
   proxy URLs, hostnames, IPv4/IPv6 addresses, ports, and bypass entries without
   external parsers. Removal does not need those values.
2. De-duplicate all selected daemon names and inspect them using `systemctl show`.
   Warn and skip unavailable units; pass only loaded units to file processing and
   restart operations. Enforce root for actual mutation and `visudo` for sudoers
   creation.
3. Render environment, profile, sudoers, or systemd content through the
   `render_*` functions. All targets pass through `process_target`, which checks
   file safety, prints a diff, and decides whether to preview, replace, or remove.
4. Replacements use a temporary file in the destination directory and a final
   move. Validate sudoers before replacement; preserve existing environment-file
   ownership and permissions. An EXIT trap cleans the outstanding temporary file.
5. Reload systemd only after drop-ins change. Restart selected services only on
   explicit request.

## Behavioral contracts

- Targets are independent. `--alldefaults` selects environment, profile, sudoers,
  and optional waagent; it does not discover arbitrary services. `--daemons`
  accepts repeated comma-separated lists of `.service` unit names. Reject
  malformed lists and unit names; de-duplicate valid selections before querying.
  The former `--extradaemons` option is retired.
- All service targets, including explicit `--daemons` and implicit waagent, use
  the same availability check (`LoadState=loaded`), not Azure identity or whether
  the service is running. Missing systemctl, failed inspection, or an unavailable
  unit warns and skips that service without blocking other targets. Leave skipped
  drop-ins untouched in configuration, preview, and removal modes. Do not add
  IMDS calls or cloud-detection dependencies. If no applicable targets remain,
  report a successful no-op without requiring root.
- Configuration requires all three values: `--http_proxy`, `--https_proxy`, and
  `--no_proxy`; an explicitly empty bypass list is valid. Render matching
  uppercase and lowercase forms of all three variables.
- Proxy URLs must be HTTP(S) host/port URLs without credentials, paths, queries,
  or fragments. Bypass entries support hosts, suffixes, IPs, CIDRs, and supported
  port forms; `*` is accepted only as the sole entry. Input validation also
  protects the different quoting rules used by the output renderers. Review all
  renderers before relaxing accepted characters or formats.
- Keep decimal bounds checks overflow-safe and IPv4 octets free of leading
  zeros. Preserve IPv6 compression and embedded IPv4 support, CIDRs with host
  bits, and contiguous dotted IPv4 subnet/host masks. IPv6 scope identifiers
  accept only URI-unreserved ASCII characters (letters, digits, `_`, `.`, `~`,
  and `-`); quotes, shell metacharacters, and URL delimiters are rejected.
- Both configuration and removal preview unless `--apply` is supplied, even
  as root. `--remove` selects removal; `--remove --apply` performs it.
  Removal cannot be combined with proxy-value options. `--preview` is retired.
  No arguments is a usage error; `--help` exits before target validation.
- Only the six proxy assignments are managed in `/etc/environment`; unrelated
  content is retained. Removal also deletes assignments predating this script
  and does not restore previous values.
- `--dropin-name NAME` defaults to `90-explicit-proxy` and controls all named
  files: profile `NAME.sh`, sudoers `NAME`, and systemd `NAME.conf`.
  `/etc/environment` is fixed and independent of the basename. Preview must show
  the resolved full paths, and removal must use the selected basename only.
  Changing the name does not migrate or remove earlier-named files.
- Basenames contain 1-250 ASCII letters, digits, underscores or hyphens, starting
  with a letter or digit. Reject paths, whitespace and extensions before any
  mutation. Dots are excluded because sudoers ignores filenames containing them;
  the length limit leaves room for `.conf` within Linux's 255-byte filename limit.
- Removal of named files requires the exact
  first-line marker `# Managed by configure-proxy.sh`; it must not remove other
  files or drop-ins. Preserve refusal to replace target symlinks or non-files.
- `--restartdaemons` requires `--apply` and selected daemon targets.
  It restarts every available selected daemon even if its drop-in is unchanged;
  skipped services never trigger a reload or restart. A
  `daemon-reload` alone does not restart services or update running environments.
- Updates are sequential, not a transaction. Failures can leave earlier targets
  changed, and failed reloads/restarts leave written files in place. Keep those
  consequences explicit; do not imply automatic rollback.
- Keep changes to supported flags, dependencies, target ownership, and lifecycle
  behavior reflected in `usage()`. CIDR bypass support varies by client; accepting
  a bypass value does not guarantee every application interprets it identically.
