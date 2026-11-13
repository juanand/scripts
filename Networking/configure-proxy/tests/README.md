# Tests and Development Checks

Development checks for [configure-proxy.sh](../configure-proxy.sh). For administrator usage and operational guidance, see the [main README](../README.md).

The tests are development tools, not prerequisites for using the script:

- [test-validation.sh](./test-validation.sh) checks input validation, preview output, and operation without Python.
- [test-removal.sh](./test-removal.sh) checks preview/apply, removal, agent names/aliases, service/manager availability, restarts, custom filenames, manager defaults, and reload diagnostics using temporary files and mocked privileges/services. Its opaque manager-version fixture is not a support claim.

Run from this `tests` directory in Linux Bash. From the workspace root, enter it with `cd tests` first:

```bash
bash -n ../configure-proxy.sh
bash -n ./test-validation.sh
bash -n ./test-removal.sh
bash ./test-validation.sh
bash ./test-removal.sh
```

Run a single case or a case-name glob from the same directory:

```bash
bash ./test-validation.sh 'IPv6 compressed proxy'
bash ./test-removal.sh 'named daemons skip unavailable unit: not-found'
bash ./test-removal.sh 'manager apply and removal are idempotent'
```

If ShellCheck is installed:

```bash
shellcheck ../configure-proxy.sh ./test-validation.sh ./test-removal.sh
```

The tests clean up their temporary files and do not modify live configuration or restart real services. They do not establish real manager activation or process inheritance, systemd integration, sudoers syntax validity, or root ownership. See [AGENTS.md](../AGENTS.md) for contributor guidance and workspace-root/WSL validation commands.
