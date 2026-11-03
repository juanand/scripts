---
name: validation
description: 'Validate multi-NIC routing scripts for Azure Debian/Ubuntu and RHEL/Rocky Linux using native NetworkManager or Netplan/systemd-networkd, and Windows Server 2022 using Windows PowerShell 5.1 or PowerShell 7. Use for NIC and gateway discovery tests, routing dry runs, source-bound connectivity, symmetric replies, idempotency, rollback, and persistence checks.'
argument-hint: '[script path] [read-only or authorized disposable-VM test scope]'
---

# Multi-NIC Routing Validation

## Outcome and Guardrails

Produce an evidence-backed validation report, not a routing implementation. Follow
[project requirements and playground topology](../../../AGENTS.md); use that file
as the source of truth for addresses, configurable aggregates, and platform constraints.

Default to read-only validation. Never apply routes on the developer workstation.
Do not install dependencies, alter Azure resources, disable firewalls, change
reverse-path filtering, restart networking, or reboot as part of routine validation.
Live mutation requires explicit authorization for named disposable targets and an
agreed recovery path. Authorization to apply does not authorize a reboot.

## Procedure

### 1. Establish the Test Boundary

- Locate the requested script, its documented parameters, and existing tests. Reuse
  available tests and fixtures rather than inventing a parallel harness.
- The single multi-distro Linux script is `linux/azure-nic-routes.sh`; its runner is
  `tests/test-linux.sh`. Select Linux behavior by verified native NetworkManager or Netplan/networkd
  ownership, not a distribution/version allowlist.
- If no script exists, report implementation-dependent checks as NOT RUN. Identify
  prerequisites and the next testable step; do not create routing scripts under this skill.
- Record target OS/version, shell/version, networking backend, installed networking
  tools, target access, and runtime-only versus persistent scope. Do not claim Rocky
  Linux results certify RHEL, or local checks certify Azure connectivity.
- Determine whether the request permits only static/fixture checks, read-only target
  inspection, or live apply/rollback tests. Ask only for missing inputs that block
  the next stage; complete independent read-only checks first.

### 2. Run Static and Isolated Checks

- For Bash, run `bash -n <script>` using an available Bash interpreter. Run ShellCheck
  only when already installed. If Bash is unavailable, mark the syntax check BLOCKED.
- For Windows, parse with both Windows PowerShell 5.1 and PowerShell 7 using
  `[System.Management.Automation.Language.Parser]::ParseFile()` and inspect all
  returned errors without executing the script. Check OS cmdlet availability separately.
- Check parameter validation, documented precedence, explicit overrides, dependency
  detection, and that dry run cannot reach mutation paths. Do not execute an unknown
  script merely because its flag is named dry run; inspect the controlling code first.
- Exercise existing isolated tests with synthetic or captured network state. Cover
  unequal/nonstandard prefixes, non-`.1` gateways, absent secondary default routes,
  reordered/renamed NICs, and primary identification ambiguity.
- Also cover invalid CIDRs, gateway/interface mismatches, overlapping aggregates and
  connected routes, existing conflicting routes/rules, unavailable evidence/tools,
  and repeated execution. On Azure Linux and Windows, test the subnet-network-plus-one fallback
  against the actual configured prefix, including non-`.1` results, override/evidence
  precedence, and rejected unsupported prefixes. Conflicting evidence must not fall
  back to calculation. Unknown results must not become arbitrary guessed routes.
- Verify fixtures cannot invoke real mutation commands. Missing fixture injection or
  mocks are a testability gap, not permission to run against local networking.

### 3. Capture Read-Only Target Evidence

- Collect IPv4 addresses/prefixes, interface identities and MACs, primary/default
  routes, policy rules/tables, and persistent configuration relevant to the script.
- On Linux, use available `ip -4 address show`, `ip -4 route show table all`, and
  `ip -4 rule show`; inspect NetworkManager/DHCP state when available. On Windows,
  use available OS cmdlets such as `Get-NetAdapter`, `Get-NetIPAddress`, and
  `Get-NetRoute`, checking active and persistent stores as applicable.
- For each NIC, record the selected source IP, actual prefix, discovered gateway,
  evidence source, and whether primary status is verified or overridden. Do not
  infer a gateway from an address alone or treat an aggregate as the NIC subnet.
  The Azure-only fallback on both platforms uses the documented subnet network address plus one
  and an actual supported prefix; distinguish it from a gateway returned by DHCP or
  configuration, and confirm the prefix against the target's Azure subnet.
- Review the script's documented dry-run output against that evidence. Verify
  primary management routing and unrelated routes/rules remain untouched.
- Record source-specific route selection before changes. On Linux, use
  `ip -4 route get <peer> from <local-IP>` for every configured source/peer pair.
  On Windows, inspect the available route-selection diagnostics with local-source
  constraints; a destination-only route listing is not proof of source-bound behavior.

### 4. Exercise Authorized Disposable Targets

- Before mutation, capture a baseline, identify script-owned changes and collisions,
  and confirm an independent recovery path such as console access. Do not proceed
  if the management session is the only recovery path.
- Use actual documented invocation parameters; never invent apply or rollback flags.
  Apply only the reviewed plan, then compare the resulting state with the baseline.
- Test each address group in the linked topology in both directions, binding probes
  to the intended local IP. Check route selection, source IP, egress NIC, gateway,
  reply path, and retained primary/management connectivity. Distinguish explicitly
  bound traffic from automatic source selection by unbound applications.
- Use source-bound ICMP where permitted and an available known permitted TCP endpoint
  when useful. Do not install listeners or change firewall rules without approval.
  Ping success alone does not establish correctness for all application flows.
- If replies are asymmetric, inspect source policy rules and effective reverse-path
  filtering. Report the evidence; do not silently change policy or kernel settings.
- Run apply a second time and confirm no duplicate routes/rules or unintended state
  changes. Exercise documented rollback and compare restored state with the baseline,
  including unrelated settings. Report residual changes precisely.
- Test persistence only if implemented and in scope. Inspect persistent state first;
  reboot only with separate authorization, then verify routes and connectivity again.

### 5. Classify Failures and Report

- Separate guest discovery/routing defects from Azure peering/transit/UDR prerequisites,
  NSGs, guest firewalls, unavailable endpoints, and missing test access. Do not infer
  cloud configuration from guest state alone or claim an ICMP failure proves routing failure.
- Mark each check PASS, FAIL, BLOCKED, or NOT RUN. PASS requires observed evidence;
  unavailable environments and unexecuted tests cannot pass by inspection.
- Report: scope/environment; exact commands and exit status; expected versus observed
  behavior; a per-source/peer result table; primary-access regression results;
  idempotency/rollback/persistence results; and remaining gaps with the next action.
- State whether any target configuration was changed and whether it was restored.
  Redact credentials and unrelated sensitive metadata from captured evidence.