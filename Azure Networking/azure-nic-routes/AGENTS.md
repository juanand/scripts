# Multi-NIC Routing Project

## Scope and Platforms

- Build guest-OS IPv4 routing automation for Azure VMs. Keep the two implementations standalone; do not introduce distro-specific forks, wrapper engines, private journals or new runtime dependencies without an explicit requirement.
- The Linux implementation is the standalone Bash script `linux/azure-nic-routes.sh`, covering Debian-family distributions (including Debian and Ubuntu) and RHEL-family distributions (including RHEL and Rocky Linux). Linux admission depends on actual per-interface backend ownership and usable capabilities, not a distribution/version allowlist. Support native NetworkManager and Netplan rendered by systemd-networkd. Native systemd-networkd without Netplan, ifupdown, wicked, and Netplan's NetworkManager renderer are not implemented. Backend admission is not target-OS certification.
- The Windows implementation is the standalone PowerShell script `windows/azure-nic-routes.ps1`, targeting Windows with either Windows PowerShell 5.1 or PowerShell 7.
- Prefer installed OS tools and built-in networking facilities. Avoid installing packages, third-party modules, or additional runtimes. Report missing prerequisites rather than installing them silently.
- Implementation, invocation examples, runtime-only limits, and validation status are in [README.md](README.md). Scripts live in `linux/` and `windows/`; dependency-free mocked tests live in `tests/`. Do not claim target-OS or Azure validation without running it there.

## Required Behavior

- The current scripts infer the primary interface from a unique guest IPv4 default-route interface; they do not use IMDS or expose a primary-NIC override. Correlate interface identity, MAC address, assigned IPv4 addresses, prefixes and routes. Never infer primary status from names, enumeration order or example addresses; fail on ambiguity.
- Discover each NIC's actual prefix and gateway from authoritative available configuration, DHCP state, or supported platform evidence. A secondary NIC may lack an installed default route. On Azure Linux and Windows guests, when gateway evidence is absent, calculate the documented Azure gateway as the actual subnet network address plus one for supported IPv4 prefixes (`/2` through `/29`), label the calculation, and retain explicit override precedence. Never guess a prefix length or append `.1` to the local address; conflicting/invalid evidence or unsupported calculation inputs require an explicit override.
- Prefer invocation parameters over script variables. Maps select NICs by containing subnet or exact assigned local `/32`; gateway overrides take precedence over discovery. Validate CIDRs, gateway/interface consistency, and ambiguous or conflicting mappings before modifying networking.
- Use RFC1918 ranges such as `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16` for configurable example destination aggregates and related NIC addresses, not hardcoded routes or NIC subnet masks. Explicitly handle destination aggregates that overlap more-specific connected routes. Translate captured example addresses consistently and label them as illustrative rather than verbatim guest evidence.
- Route each configured destination aggregate through the matching NIC's actual subnet gateway. Preserve the existing primary default route and management connectivity; do not add competing secondary default routes to the main table.
- Do not assume peers share a VNet, subnet, or subnet size. Guest routes cannot create Azure peering, transit, UDRs, or NSG/firewall permission; report these as separate connectivity prerequisites.
- Evaluate locally initiated and inbound/reply traffic separately. On Linux, verify whether destination routes suffice or source-based policy routing is needed for symmetric replies. Do not promise arbitrary source-address behavior from destination routes alone. Diagnose reverse-path filtering before proposing a narrowly justified change; never disable it globally by default.

## Change Safety and Persistence

- Separate discovery, plan, apply, and verification. Preview must not mutate networking. Mutation requires root on Linux or Administrator elevation on Windows; protected Netplan sources may also require root for read-only inspection. Elevation alone never authorizes apply.
- Make repeated execution idempotent. The default metric `42762` is a recognition convention, not proof of route authorship: rollback can remove matching manual routes. Reset removes eligible manual routes across metrics, never defaults, connected/DHCP routes, profiles or non-route settings. Never flush tables or change unrelated rules.
- Batches are not atomic; failures can leave earlier changes. Preserve state rechecks, explicit failure reporting and saved-first cleanup ordering. Never perform live networking changes without explicit authorization for a named disposable target and a recovery path; reboot requires separate approval.
- Document whether changes are runtime-only or persistent. For Linux persistence, use the verified active backend: native NetworkManager profiles or route-only Netplan overlays for systemd-networkd. Preserve authoritative configuration and unrelated settings; do not assume legacy network-scripts exist. Avoid network restarts, Netplan apply, or disruptive profile reactivation without explicit approval.
- On Linux, prefer Bash plus installed `ip`, core utilities, and the native tools required by the verified NetworkManager or Netplan/networkd backend; do not introduce Python, Node.js, `jq`, Azure CLI, or SDK dependencies by default. Detect required tools and avoid parsing human-readable output when stable machine-readable output is available without new dependencies.
- On Windows, support both Windows PowerShell 5.1 and PowerShell 7 using OS-provided networking cmdlets/APIs; verify their availability and compatibility on Server 2022. Keep scripts ASCII for Windows PowerShell parsing and preserve equivalent configurable behavior and safety guarantees.

## Implementation Contracts

- Linux runtime operations also validate backend ownership. Do not remove those checks merely because `--persist` is absent.
- Native NetworkManager persistence requires an active profile saved under `/etc`, autoconnect enabled and no user restrictions. Never automatically promote a `/run` profile: that changes whole-profile boot configuration beyond route management.
- Linux can save matching runtime routes without removing them. Rollback/reset inspect saved configuration even for runtime-only routes, so their persistent-owner prerequisites still apply.
- Windows creates runtime routes with `-PolicyStore ActiveStore`; persistent creation omits `PolicyStore` to populate both stores. Matching active-only routes require reviewed rollback before persistent apply; do not silently replace them or pass `-PolicyStore PersistentStore` to `New-NetRoute`.
- Saved DHCP routes omit fixed preferred sources; matching source-free routes after reboot are valid. Retain preferred sources for validated manual/static profiles.
- Accept only ordinary rules or the strictly validated `nm-cloud-setup` layout described in [README.md](README.md#existing-cloud-policy). Preserve source rules and auxiliary tables; compatibility is not arbitrary-source pinning.
- Netplan persistence uses owned route-only overlays and native compilation in private temporary directories. Prefer native `configure` when installed, otherwise `generate`; mapping uses `generate`. Do not use the CLI `netplan generate` wrapper, which can request service reloads, or bypass a compiler failure.
- Keep diagnostics off structured helper stdout. Propagate failed reads explicitly; never treat failure as an empty snapshot or rely solely on Bash `set -e` in conditionally invoked functions.

## Playground and Verification

Use this topology as test data only; subnet masks and gateways are deliberately unspecified:

| VM   | Primary IPv4 | Secondary IPv4 | Secondary IPv4 |
| ---- | ------------ | -------------- | -------------- |
| VM01 | 10.0.0.5     | 172.16.0.4     | 192.168.0.4    |
| VM02 | 10.0.1.5     | 192.168.1.4    | 172.16.0.132   |

- Baseline: primary-network addresses communicate both ways; secondary-network addresses do not. Target: bidirectional connectivity between corresponding primary, secondary-A, and secondary-B addresses on both VMs, retaining primary access.
- For script/test changes, run `bash -n` on both Bash files, `bash tests/test-linux.sh`, `powershell.exe -NoProfile -NonInteractive -File tests/test-windows.ps1`, and `pwsh -NoProfile -File tests/test-windows.ps1`; parse both Windows files with both engines. Run `shellcheck linux/azure-nic-routes.sh tests/test-linux.sh` when installed; never install it as a runtime prerequisite. Preserve narrow, documented lint annotations rather than rewriting intentional guards or fixture isolation merely to silence lint.
- Use [the validation skill](.github/skills/validation/SKILL.md) for the detailed procedure and [README.md](README.md#tests) for development checks. Documentation-only edits need relevant link/snippet checks; runtime changes need focused regression coverage, with target-VM testing for affected behavior.
- Test discovery and dry-run logic using captured or synthetic network state without changing the developer machine's routes. Cover nonuniform prefixes, non-`.1` gateways, missing secondary default routes, reordered NICs, ambiguous discovery, conflicting routes, and invalid parameters.
- On disposable target VMs, inspect source-specific route selection (Linux: `ip route get <peer> from <local-IP>`) and exercise source-bound traffic in both directions for each address family above. Check egress interface, gateway, source address, reply path, unchanged primary access, second-run idempotency, and rollback. Verify reboot persistence when supported.
- Distinguish syntax/fixture checks from real connectivity tests. Record exact environments and commands tested; an ICMP failure alone does not prove a routing defect.
- Check native exit codes and explicit completion summaries before claiming success. Echoed commands, missing output and unexecuted tests are not passing results.

On Windows with an existing WSL Bash environment, run from the repository root:

```powershell
wsl.exe --exec env TMPDIR=/var/tmp bash tests/test-linux.sh
wsl.exe --exec shellcheck linux/azure-nic-routes.sh tests/test-linux.sh
```

The second command requires ShellCheck to be installed. For Bash snippets supplied
from PowerShell, pipe the text to `wsl.exe --exec bash --noprofile --norc -n -s` for
syntax-only checks. Do not pass snippets containing command substitutions through
`bash -c`: the command transport can evaluate them before syntax checking.

## Documentation and Collaboration

- README is the administrator guide, not a feedback log. Preserve the user's wording unless correcting accuracy or clarity; keep alternative command modes together when clearly labelled as alternatives.
- For requested manual-edit reviews, provide exact Ctrl+F text and handle one agreed finding at a time. Do not edit files in response to a read-only question or review.
- Keep this file focused on reusable constraints and commands. Put lengthy procedures in the validation skill or README; do not add chat history, machine-specific reports or duplicated test counts here.

## References

- [Azure Linux multiple NICs on different subnets (internal wiki)](https://supportability.visualstudio.com/AzureIaaSVM/_wiki/wikis/AzureIaaSVM/495893/Multiple-NICs-on-Same-VNet-but-Different-Subnets_Linux): requires authentication; rely on its contents only after accessing and verifying them.
- [Configure the Windows guest OS for multiple NICs](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/multiple-nics#configure-guest-os-for-multiple-nics): consult for platform context, but do not copy illustrative gateway or subnet assumptions into discovery logic.
