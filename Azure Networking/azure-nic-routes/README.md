# Azure NIC Routes

## Overview

The purpose of these **human-tested**, **vibe-coded scripts** is to simplify the configuration of guest-OS IPv4 destination routes for Azure VMs with multiple NICs.

VMs in Azure can have multiple virtual network interface cards (NICs) attached to them. A common scenario is to have different subnets for front-end and back-end connectivity. You can associate multiple NICs on a VM to multiple subnets, but those subnets must all reside in the same virtual network (vNet).

Azure’s [documented default configuration](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/multiple-nics#configure-guest-os-for-multiple-nics) provides a guest-OS default gateway (subnet network address plus one) for the primary NIC. By default, secondary NICs only get connected-subnet routes, allowing same-subnet communication (when network and firewall policies permit).

Without an appropriate guest OS route through a secondary NIC, the guest OS may send off-subnet traffic through the primary NIC leveraging its default gateway. If a reply leaves through the primary NIC while retaining the secondary NIC’s source IP, Azure drops it when IP forwarding is disabled on the outgoing NIC. Depending on the operating system and existing configuration, explicit destination routes, sometimes combined with source-based policy routing, may be required to keep the reply’s source address and outgoing NIC aligned. While Azure peering and UDRs govern Azure-side forwarding, they do not replace guest-OS route selection.

## About the Scripts

These scripts add non-default IPv4 destination routes through selected NICs, using each NIC's actual subnet gateway. Mappings can select either primary or secondary NICs. The existing primary default route and connected routes are preserved; no competing secondary default routes are added. There are two scripts:

- **Linux:** [linux/azure-nic-routes.sh](linux/azure-nic-routes.sh), one multi-distro Bash script for Debian/Ubuntu and RHEL/Rocky families. See [Linux Operations](#linux-operations) for commands, persistent behavior and backend requirements.
- **Windows:** [windows/azure-nic-routes.ps1](windows/azure-nic-routes.ps1), using Windows PowerShell 5.1 or PowerShell 7. See [Windows Operations](#windows-operations) for commands and persistence behavior.

The scripts implement several options, using main parameters (see script's help for additional parameters):

| Intent                       | Linux Options          | Windows Options      |
| ---------------------------- | ---------------------- | -------------------- |
| Preview routes               | Omit `--apply`       | Omit `-Apply`      |
| Preview persistence          | `--persist`          | `-Persist`         |
| Apply runtime-only routes    | `--apply`            | `-Apply`           |
| Apply routes across reboots  | `--apply --persist`  | `-Apply -Persist`  |
| Preview rollback            | `--rollback`         | `-Rollback`        |
| Apply rollback               | `--apply --rollback` | `-Apply -Rollback` |
| Preview reset across metrics | `--reset`            | `-Reset`           |
| Apply reset across metrics   | `--apply --reset`    | `-Apply -Reset`    |

With valid mappings and without `--apply` (Linux) or `-Apply` (Windows), the scripts run in preview mode and make no routing changes in the guest OS. Both scripts require at least one mapping for route additions; invoking them without arguments reports an error rather than displaying a routing plan.

In **apply mode** (`--apply` in Linux, `-Apply` in Windows), the scripts **apply temporary routing changes that do not survive a guest OS reboot,** useful for testing purposes.

In **persist mode** (`--apply --persist` in Linux, `-Apply -Persist` in Windows) the scripts apply **persistent routing changes**. Preview the intended configuration, then choose runtime-only or persistent apply. Runtime-only testing is optional. If matching runtime-only routes already exist, Windows requires reviewed rollback before persistent apply; Linux can save them without removing the live routes.

Having Serial Console access will be needed if routing changes break network connectivity to the VM.

To define routing changes, the scripts use the concept of `maps`, where you can map the NIC IP address or CIDR range to one or more destination ranges, using `--map` in Linux and `-Map` in Windows. See the operations sections below for details.

The scripts implement two cleanup modes: **rollback** and **reset**. Rollback removes eligible manual non-default routes matching the selected metric, which defaults to `42762` and can be changed with `--metric` or `-Metric`. Manually created routes using the same metric may also be removed; the scripts do not track route authorship.

Reset removes eligible manual non-default routes across all metrics within its supported interface and backend scope. Both modes include saved and live routes while preserving defaults, connected routes, DHCP-learned routes and profiles.

Cleanup takes no mappings, gateway overrides or persistence option. Without the apply flag, it only previews removals. Review the plan before applying cleanup from a console with recovery access.

Notice that **destination routes alone do not guarantee arbitrary-source reply symmetry**. Verify source-bound and unbound traffic in both directions, primary access, repeat apply, and persistence after a separately planned reboot. Azure peering/transit, UDRs, NSGs, guest firewalls and application permissions remain separate prerequisites. Also notice that an ICMP or TCP failure alone does not prove a guest OS routing problem: NSG rules, UDRs, OS firewalls and NVAs may affect as well.

Note: **Source-bound** means the application selects a local source address; **unbound** means the OS selects it.

## Manual Workflow

Without these scripts, an administrator would perform the following work for each VM and selected NIC. Linux persistence depends on the active configuration owner, not whether the distribution belongs to the Debian or RHEL family.

| Task                                                          | Linux Manual Equivalent                                                                                                                                                                 | Windows Manual Equivalent                                                                                                                                                     |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Discover NICs, actual prefixes, gateways and existing routing | `ip -o -4 address show scope global`, `ip -4 route show table all`, `ip -4 rule show`; inspect `nmcli device show` or `networkctl status` and the authoritative configuration | `Get-NetIPConfiguration`, `Get-NetIPAddress -AddressFamily IPv4`, and `Get-NetRoute` for both `ActiveStore` and `PersistentStore`                                   |
| Validate the plan                                             | Confirm gateway/subnet consistency, the primary default, overlapping destinations, connected routes, saved configuration and existing source policies                                   | Confirm gateway/subnet consistency, the selected interface index, the primary default and conflicts in both route stores                                                      |
| Install a live destination route                              | `ip -4 route add` with the actual gateway, interface, preferred source and metric                                                                                                     | `New-NetRoute -PolicyStore ActiveStore` with the actual interface index, next hop and metric                                                                                |
| Save across reboot                                            | Append a route with `nmcli connection modify ... +ipv4.routes`, or maintain a route-only Netplan overlay for systemd-networkd                                                         | Create the route with `New-NetRoute` **without** `-PolicyStore`, which saves it in both stores                                                                      |
| Verify                                                        | `ip -4 route get <peer> from <local-IP>` and `ping -I <local-IP> <peer>`; compare saved/live routes and primary access                                                              | `Test-NetConnection -DiagnoseRouting -ConstrainSourceAddress <local-IP> -ComputerName <peer>`, `ping.exe -S <local-IP> <peer>`, and both route stores                     |
| Undo reviewed changes                                         | Remove the exact saved entry using `-ipv4.routes` or the owned Netplan route stanza, then the live entry using `ip -4 route del`                                                    | Remove exact matching entries using `Remove-NetRoute`, saved entries first (`PersistentStore`), then remaining live entries (`ActiveStore`); use `-WhatIf` to preview |

For example, assume a verified local address `172.16.0.132/25`, gateway `172.16.0.129`, and destination aggregate `172.16.0.0/12`. The corresponding NIC is `eth1` on the example Linux VM or interface index `7` on the example Windows VM.
With recovery access and after validation, the administrator could add this **runtime-only** route:

```bash
sudo ip -4 route add 172.16.0.0/12 via 172.16.0.129 dev eth1 \
  src 172.16.0.132 proto static metric 42762
```

Or, in an elevated Windows PowerShell 5.1 or PowerShell 7 session:

```powershell
New-NetRoute -DestinationPrefix '172.16.0.0/12' -InterfaceIndex 7 `
    -NextHop '172.16.0.129' -RouteMetric 42762 -Protocol NetMgmt `
    -AddressFamily IPv4 -PolicyStore ActiveStore
```

For Linux persistence, save the appropriate backend configuration before adding the live route. A suitable native NetworkManager profile receives a saved tuple such as `172.16.0.0/12 172.16.0.129 42762 table=254`; a Netplan overlay adds the equivalent `to`, `via`, `metric` and `table` fields under the existing definition ID. Saved DHCP routes omit a fixed preferred source to avoid boot ordering failures. See [NetworkManager Persistence](#networkmanager-persistence) and [Netplan Persistence](#netplan-persistence). Neither method requires the scripts to reactivate a profile, run `netplan apply`, or restart networking.

For Windows persistence, omit `-PolicyStore ActiveStore` from the creation command instead of running both variants. An existing active-only route requires reviewed removal before its persistent replacement. Do not pass `-PolicyStore PersistentStore` to `New-NetRoute`; see [Microsoft&#39;s route-store semantics](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netroute#-policystore).

The scripts automate the validation around these commands: read-only preview, NIC/gateway discovery, conflict detection, skipping already-correct routes, backend-specific saving, post-change route checks and scoped cleanup. Repeating a manual `add` command does not reproduce that idempotent workflow. Only reviewed route entries change; defaults, connected/DHCP routes, profiles and unrelated settings are retained. Batches are not atomic, so a failure can leave earlier
changes that need inspection and recovery.

The scripts also allow to use a single, bulk, command line that can be shared across deployments for VMs with common routing needs, using `maps` that map a broad NIC mask for all VMs with one or more destination masks, without having to care about the individual NICs IP addresses or the IP address of the gateway for the NIC's subnet.

Administrators still need to test traffic in both directions, including bound and unbound sources, confirm primary access, and verify persistence after a separately planned reboot. Linux `src` is a preferred source, not address rewriting; Windows selects its source address.

## Platforms

Linux script supports Debian/Ubuntu and RHEL/Rocky families through verified native NetworkManager or Netplan/systemd-networkd ownership. Backend selection is per interface, not based on a distribution/version allowlist or installed CLI alone.
Native networkd without Netplan, ifupdown, wicked and Netplan's NetworkManager renderer are not implemented. Backend admission is not target-OS certification.

| Backend               | Installed Requirements                                                                                                                              |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native NetworkManager | Bash, iproute2, core utilities and compatible nmcli; saved profiles under /etc                                                                      |
| Netplan/networkd      | Bash, iproute2, core utilities, awk, stat, sha256sum, native Netplan generator, networkctl and busctl; Netplan CLI for optional DHCP lease evidence |
| Windows               | Windows PowerShell 5.1 or PowerShell 7 with OS-provided NetTCPIP, NetAdapter and CIM cmdlets; Windows Server 2022 is the target server platform     |

Nothing is installed automatically. Native `configure`/`generate` executables are sought under `/usr/libexec/netplan`, `/usr/lib/netplan` and `/lib/netplan`.
Its CLI is also sought under `/usr/sbin` and `/sbin` when missing from PATH. Invalid/missing prerequisites fail before route mutation. 
Run only on the intended Azure VMs, not the management workstation.

## Common Behavior

The following behaviors are common across Linux and Windows variants:

- Preview is the default; Apply mode is required to change routes. Applying changes requires root on Linux or an elevated Administrator session on Windows. Retain Serial Console/local recovery.
- Maps use `NIC_SELECTOR=DESTINATION1,DESTINATION2`. The left side selects a usable local NIC address, actual subnet or broad CIDR range; it does not configure a subnet mask. The right side contains destination networks, not local address assignments.
- A subnet selector must contain the actual NIC subnet: `172.16.0.0/24` can select a NIC in `172.16.0.132/28`, but not in `172.16.0.132/16`. Alternatively, `/32` matches one exact assigned local address: `172.16.0.132/32=172.16.0.0/16` selects that address while retaining its actual NIC prefix for gateway discovery and validation.
  An unassigned address does not match, even inside a local subnet. Duplicate matches are refused; overlapping selectors remain errors. NIC names, order, and example addresses do not determine primary status.
- Unmatched NIC maps warn and skip; matching maps can still apply. All-unmatched plans are successful no-ops. Invalid CIDRs and overlapping/conflicting mappings remain errors, including invalid destinations in skipped maps.
- The primary NIC is identified from a unique default-route interface. Ambiguous default routing requires manual review. No secondary default routes are added.
- More-specific same-NIC connected routes remain direct. An exactly connected destination needs no gateway route. Other more-specific conflicts are refused.
- Matching route tuples are skipped on repeated apply. Existing conflicting routes are not overwritten. Use rollback and preview again before changing a metric.
- Runtime-only additions may disappear after reboot/network reconfiguration. Runtime-only apply does not undo previously saved persistent routes.
- Rollback removes eligible manual routes with the selected metric, default `42762`. Reserve that metric: an identical manually created route cannot be distinguished. Metric is customizable using parameter. Windows `-Metric` accepts `1..65535` because the native route cmdlets use UInt16. Linux `--metric` accepts decimal `1..4294967295` without leading zeros. Use the same value on repeat runs and rollback.
- Longest-prefix matching comes before route metrics; otherwise Windows combines route and interface metrics. The script never changes interface metrics or forces a source address.
- Reset removes eligible manual routes across all metrics. Both cleanup modes include saved entries automatically and preserve defaults, connected/kernel and DHCP-learned routes. Cleanup is separate from maps and persistence options.
- Only route entries change: no DNS, MTU, address, DHCP, IPv6, firewall, forwarding, interface-metric, or reverse-path-filtering settings; no profile deletion, interface restart, network restart, custom routing tables, or policy rules.
- Batches are not atomic. A failure can leave earlier changes in place. Inspect the error and state, then retry or roll back. Do not run concurrent instances.


### Gateway Precedence

In most cases, the scripts detect the IP address for the subnet gateway to use as next-hop in the static route without any explicit indication. However, the scripts also accept an **optional gateway parameter** to override gateway detection.

Gateway precedence is **explicit override > consistent discovered evidence > labelled Azure subnet-network-plus-one calculation**.

Discovered evidence comes from consistent installed-default, native configuration, and actual DHCP-router evidence where available. Without evidence, this Azure-only implementation calculates the actual subnet network plus one for `/2` through `/29`, labels the calculation, and validates it. For example, `172.16.0.132/28` gives `172.16.0.129`; `192.168.1.4/23` gives `192.168.0.1`, not `192.168.1.1`. Conflicting/invalid evidence requires an override, not a calculation.

When using a gateway parameter, the explicit gateway overrides precede automatic gateway discovery. This is not required in most cases, and gateways must be valid hosts in the actual NIC subnet, not local addresses, subnet networks, or broadcast addresses. 

The following example assumes a selected local address of `172.16.0.132/28` and a verified gateway of `172.16.0.129`. Replace these illustrative values with your actual configuration. Run from the directory containing the Linux script. Both commands use identical mappings, gateway, metric and persistence settings; only the second command applies changes.

```bash
route_options=(
  --map 172.16.0.132/32=172.16.0.0/12
  --gateway 172.16.0.132/32=172.16.0.129
  --metric 50000
  --persist
)

# Preview, including persistence validation
bash azure-nic-routes.sh "${route_options[@]}"
# Apply with persistence after reviewing the preview
sudo bash azure-nic-routes.sh --apply "${route_options[@]}"
```

Protected Netplan configuration may require `sudo` for the preview too;
without `--apply`, it remains read-only.


## Linux Operations

Linux script variant reports detected OS metadata, and the verified backend for each interface. The script reads `/etc/os-release` before network operations to report `ID`, `VERSION_ID` and `ID_LIKE`. None is compared with a distribution/version allowlist; `VERSION_ID` and `ID_LIKE` may be absent. Unreadable metadata or a missing `ID` still fails discovery.

Backend selection still uses actual per-interface ownership, not the distro family. Native NetworkManager interfaces report `NetworkManager; tool=nmcli`. Older Netplan installations report `compiler=generate`. Cleanup modes report `persistence=automatic-cleanup` because they include saved entries without a `--persist` option. These diagnostics do not change routing, validation, supported backends or CLI behavior. Before route additions, each mapped interface needs a verified native NetworkManager or Netplan/networkd owner and usable installed native tooling.

Missing/incompatible tooling, unsupported or ambiguous ownership, and conflicting route/policy state still fail before mutation. No packages are installed or networking managers switched. Admission is not certification of an OS/version.

Example:

```text
OS: ID=ubuntu VERSION_ID=26.04 ID_LIKE=debian
MODE: preview; operation=routes; persistence=no; runtime routes use ip
BACKEND eth1: Netplan -> systemd-networkd; compiler=configure
```


### Preview and Apply

The following examples illustrate three execution modes: preview, runtime-only apply, and persistent apply. Replace the illustrative mappings with your topology and preview the intended configuration first. Then choose the apply mode you need; these examples are alternatives, not a sequence to run in full:

```bash
routes=(
  --map 10.0.0.0/8=10.0.0.0/8,172.20.0.0/16
  --map 172.16.1.0/24=172.16.0.0/16
  --map 192.168.0.10/32=192.168.0.0/16
)
# Preview
bash azure-nic-routes.sh "${routes[@]}"
# Apply without persistence
sudo bash azure-nic-routes.sh --apply "${routes[@]}"
# Apply with  persistence
sudo bash azure-nic-routes.sh --apply --persist "${routes[@]}"
```

Alternatively, pass each mapping directly with repeated `--map` parameters:

```bash
# Preview
bash azure-nic-routes.sh \
  --map 10.0.0.0/8=10.0.0.0/8,172.20.0.0/16 \
  --map 172.16.1.0/24=172.16.0.0/16 \
  --map 192.168.0.10/32=192.168.0.0/16

# Apply without persistence
sudo bash azure-nic-routes.sh --apply \
  --map 10.0.0.0/8=10.0.0.0/8,172.20.0.0/16 \
  --map 172.16.1.0/24=172.16.0.0/16 \
  --map 192.168.0.10/32=192.168.0.0/16

# Apply with persistence
sudo bash azure-nic-routes.sh --apply --persist \
  --map 10.0.0.0/8=10.0.0.0/8,172.20.0.0/16 \
  --map 172.16.1.0/24=172.16.0.0/16 \
  --map 192.168.0.10/32=192.168.0.0/16
```

Running `--map` without `--apply` is a preview, does not change any route, even `--persist` without `--apply` is still a preview.

Running `--map` with `--apply` requires sudo, and applies temporary changes that don't survive a system reboot. Only using `--map` together with both `--apply` and `--persist` make changes persist across reboots.

For runtime and persistent route additions, each mapped interface needs a verified supported configuration owner. Mixed native NetworkManager and Netplan/networkd interfaces are allowed; two managers claiming the same interface are refused. Unknown ownership, additional networkd drop-ins and active/saved non-route setting differences require review.

Matching runtime-only routes can later be saved by running the same configuration with `--apply --persist`; rollback is not required.

For additional optional parameters, run the script with `--help`.

### Existing Cloud Policy

The Linux script accepts the narrowly validated source-policy layout used by Azure `nm-cloud-setup`, independently of distro/version. It does not merely whitelist table numbers or require the service to be running at the moment of inspection. The service can be inactive between timer-triggered runs; leave the service/timer configuration unchanged.

Compatibility currently requires all usable global IPv4 addresses to belong to active native NetworkManager profiles, with one address per NIC. Each source must have matching host-source rules whose priorities and table IDs are `30200 + index` and `30400 + index`, with index 0 through 99. The usual local/main/default rules and exactly one `30350` main-table lookup with `suppress_prefixlength 0` are required.
Static protocol can be named or numeric; additional selectors and missing, duplicate, unpaired or shared-table rules are refused.

Each `30200 + index` table must contain exactly the NIC's actual direct subnet route; each `30400 + index` table must contain exactly its validated gateway default. These routes must use static protocol and metric 10. Unexpected auxiliary tables/routes, conflicting gateways, or unsupported prefixes require manual review. NIC names and enumeration order do not determine policy identity.

The script adds only non-default destination routes in `main` (`table=254`). It never creates, deletes or rewrites the existing policy rules or auxiliary routes. Rule 30350 permits specific main-table routes to take precedence over per-source defaults. This does not guarantee arbitrary-source symmetry: verify source-bound and unbound traffic separately. Source policy, addresses and backend ownership
are rechecked before writes, with further policy checks around individual changes and after completion. Detected concurrent changes stop the operation; earlier route changes can remain and need reviewed recovery.

For persistence and saved-route cleanup, native profiles must also satisfy the normal disk-backed/autoconnect requirements below. Saved `ipv4.routing-rules` must be empty and `ipv4.route-table` must be 0 or 254; saved routes must not target auxiliary tables. Other saved policy configurations are not silently adopted.
Only saved `ipv4.routes` entries are modified. A matching manual runtime route with the reserved metric can be saved without duplicating it.

Review a persistent preview before applying routes alongside cloud policy. Verify source-specific route selection and connectivity, including after cloud policy refresh and any separately planned reboot.

### NetworkManager Persistence

An active native NetworkManager profile must be saved under `/etc`, with autoconnect enabled and no user restrictions. Generated `/run` profiles are not adopted. The script never connects/reactivates a profile or switches managers. Storage refusals now identify the interface, active profile UUID and reported path.
See [Known Issues](#known-issues) for read-only inspection and conditional manual preparation; no profile is saved automatically.

Only `ipv4.routes` entries are appended, using the active storage backend, normally keyfiles under `/etc/NetworkManager/system-connections/` or supported ifcfg storage.

Profiles are not reactivated. An identical runtime plan can be saved with a later `--apply --persist`. Verify reboot behavior separately with recovery access.

For DHCP profiles (`ipv4.method=auto`), saved routes contain destination, gateway,  metric, and `table=254`, but no fixed `src=`. This avoids boot-time route rejection when NetworkManager installs static routes before the DHCP address becomes local.
The rule applies to both RHEL/Rocky 8 and 9. Manual IPv4 profiles retain saved preferred sources; unsupported or unreadable IPv4 methods block persistence.
New runtime routes still specify the selected source. Matching post-boot routes without an explicit preferred source are left unchanged; Linux selects the source from the egress interface. Explicitly conflicting sources or other route fields
remain errors.

Older DHCP entries containing `src=` are not silently replaced. If a saved-route collision is reported, preview metric-based rollback, review it from a console, apply the reviewed cleanup, and rerun with `--apply --persist`. This includes saved entries automatically; no profile restart is needed.

### Netplan Persistence

The active networkd file must agree with the native Netplan definition, its exact live MAC identity and saved non-route settings. Interface names alone never prove ownership. Symlinked, unreadable, non-root-owned or group/world-writable Netplan sources are refused. Unusual definition/source filenames fail closed.

Persistence writes only a reserved route-only overlay at `/etc/netplan/90-multinic-<definition-ID>.yaml`, mode 0600. It does not modify cloud-init YAML or generated live files. Existing source sequences are retained by native [Netplan merging](https://netplan.readthedocs.io/en/stable/netplan-generate/).
A reserved overlay with other settings/comments/formatting is refused rather than rewritten. Configuration snapshots and ownership are rechecked before mutation. The complete plan is compiled in a private temporary root first, including collision/pending-policy checks and exact native metric serialization. A metric supported by iproute2 can still be refused for persistence when Netplan cannot retain it; no runtime downgrade occurs.

Offline validation uses installed native Netplan executables: `configure` when available, otherwise the older native `generate`; interface mapping uses `generate`.
It does not invoke the `netplan generate` CLI wrapper, which can request service reloads even with a temporary root. Compiler failures are not bypassed. Protected configuration files can require `sudo` for a read-only preview; do not loosen their permissions. Private validation directories are removed on exit.

DHCP routes omit `from` to avoid boot-time preferred-source ordering problems.
Manual-address profiles retain the selected source only if that static address is present in saved Netplan configuration. Runtime routes initially specify `src`; matching source-free routes are accepted after boot. No Netplan apply, renderer reload or service restart is run; live additions use `ip` and the overlay is consumed by normal boot/administrator-controlled regeneration. Later configuration changes or interface reconfiguration can replace runtime-only routes.

### Rollback and Reset

```bash
bash azure-nic-routes.sh --rollback --metric 50000
sudo bash azure-nic-routes.sh --rollback --metric 50000 --apply
bash azure-nic-routes.sh --reset
sudo bash azure-nic-routes.sh --reset --apply
```

Omit `--metric` for default-metric rollback. Reset rejects `--metric`; cleanup rejects maps, gateway overrides, and `--persist`.

Linux rollback/reset inspect both saved configuration and live routes, even when routes were added without `--persist`. Cleanup requires supported configuration ownership. Native NetworkManager profiles must satisfy the disk-backed `/etc`, autoconnect and permission requirements described above. If these prerequisites are not met, cleanup refuses before removing routes. Preview cleanup before relying on it as a recovery method.


### Inspect and Verify

Run these checks before and after applying changes. Replace the illustrative
interface, local address and peer address with values from your environment.

```bash
interface=eth1
local_ip=172.16.0.132
peer_ip=172.16.1.4

ip -o -4 address show scope global
ip -4 route show table main
ip -4 rule show
ip -4 route get "$peer_ip"
ip -4 route get "$peer_ip" from "$local_ip"

ping -c 4 "$peer_ip"
ping -I "$local_ip" -c 4 "$peer_ip"
```

Compare the selected interface (`dev`), gateway (`via`) and source address with
the reviewed plan. The two route lookups check automatic source selection and
an explicitly selected source separately. Confirm that the primary default route
and management access remain unchanged. When policy routing is present, also
inspect `ip -4 route show table all`.

If `--persist` was used, inspect the saved configuration using the active backend.

**NetworkManager**

```bash
profile_uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$interface")
sudo nmcli --fields connection,ipv4 connection show uuid "$profile_uuid"
nmcli -g ipv4.routes connection show uuid "$profile_uuid"
```

**Netplan/systemd-networkd**

Use the actual Netplan definition ID, which may differ from the interface name.
The route overlay exists after a successful persistent apply.

```bash
definition_id='<NETPLAN_DEFINITION_ID>'
sudo cat "/etc/netplan/90-multinic-${definition_id}.yaml"
networkctl --no-pager status "$interface"
```

Saved DHCP routes normally omit a fixed preferred source. A matching live route
without `src` after reboot is therefore expected, not evidence of failed persistence.

If incoming traffic or replies fail, inspect reverse-path filtering without changing it:

```bash
sysctl net.ipv4.conf.all.rp_filter "net.ipv4.conf.${interface}.rp_filter"
```

Diagnose the routing and filtering behavior before changing any setting; do not
disable reverse-path filtering globally as a default remedy.

Repeat source-bound probes in the reverse direction for every mapped address group. Route lookups do not prove connectivity, and failed pings may reflect ICMP filtering.
Test a known permitted application endpoint as appropriate. Confirm repeat-apply idempotency and reviewed cleanup, and repeat persistence checks after a  separately planned reboot with recovery access. These inspection commands do not change network configuration, reactivate profiles or restart networking.


## Windows Operations

### Preview and Apply

For Windows script variant, use a single `-Map` with a quoted string array, not repeated `-Map` or Bash-style `--map`. 

The following examples illustrate three execution modes: preview, runtime-only apply, and persistent apply. Replace the illustrative mappings with your topology and preview the intended configuration first. Then choose the apply mode you need; these examples are alternatives, not a sequence to run in full:

```powershell
# Preview
$maps = @(
  '172.16.0.0/12=172.16.0.0/12'
  '192.168.0.0/16=192.168.0.0/16'
)
# Preview
.\windows\azure-nic-routes.ps1 -Map $maps
# Apply without persistence
.\windows\azure-nic-routes.ps1 -Map $maps -Apply
# Apply with persistence
.\windows\azure-nic-routes.ps1 -Map $maps -Apply -Persist
```

Alternatively, pass the mappings directly as a single string array:

```PowerShell
# Preview
.\windows\azure-nic-routes.ps1 `
-Map @("172.16.0.0/12=172.16.0.0/12","192.168.0.0/16=192.168.0.0/16")
# Apply without persistence
.\windows\azure-nic-routes.ps1 `
-Map @("172.16.0.0/12=172.16.0.0/12","192.168.0.0/16=192.168.0.0/16") -Apply
# Apply with  persistence
.\windows\azure-nic-routes.ps1 `
-Map @("172.16.0.0/12=172.16.0.0/12","192.168.0.0/16=192.168.0.0/16") `
-Apply -Persist
```

Applying changes needs an elevated Administrator shell.

If matching runtime-only routes already exist, preview and apply rollback using their original metric before applying persistent routes.

While on Linux matching runtime-only routes can later be saved by running the same configuration with --apply --persist without requiring a rollback operation, Windows creates persistent routes using New-NetRoute, which populates both **`PersistentStore` and `ActiveStore`**. The script deliberately rejects an existing active-only route rather than automatically removing and recreating it. This is a safety restriction in the current Windows implementation, not a general statement that Windows always needs rollback before persistent routing. Thus, preview → persistent apply works directly on both platforms, but apply → persistent apply in Windows requires rollback first.

Runtime creation explicitly uses `-PolicyStore ActiveStore`. Persistent creation omits `PolicyStore`, using the documented native behavior of saving into both stores; both are checked afterward. **If matching active-only routes already exist, preview and apply rollback first, then apply with `-Persist`.** The script refuses automatic replacement just to enable persistence. No registry files or private files are edited directly. Inspect native persistent routes to confirm the saved result.

Use `Get-Help .\windows\azure-nic-routes.ps1 -Full` for native parameter help and more examples.


### Rollback and Reset

```powershell
.\windows\azure-nic-routes.ps1 -Rollback -Metric 50000
.\windows\azure-nic-routes.ps1 -Rollback -Metric 50000 -Apply
.\windows\azure-nic-routes.ps1 -Reset
.\windows\azure-nic-routes.ps1 -Reset -Apply
```

Omit `-Metric` for default-metric rollback. Reset rejects `-Metric`; cleanup rejects maps, gateway overrides, and `-Persist`. 

Cleanup removes eligible PersistentStore entries first, then ActiveStore entries. Scope is non-default IPv4 `NetMgmt` manual routes on the currently usable Ethernet NICs in the default compartment. Other protocols, defaults, Local/connected and DHCP routes, and other NICs are retained.
No adapters or network profiles are deleted, disabled, or restarted.

Use a local/Serial Console for cleanup. Detected SSH is refused, but RDP and WinRM management clients are not automatically identified; route removal can interrupt those sessions even when defaults remain intact.

### Inspect and Verify

```powershell
Get-NetIPAddress -AddressFamily IPv4
Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore
Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore
Test-NetConnection -ComputerName 172.16.1.4 -DiagnoseRouting `
    -ConstrainSourceAddress 172.16.0.132 -InformationLevel Detailed
ping.exe -S 172.16.0.132 -n 4 172.16.1.4
```

Repeat source-bound probes in the reverse direction for every mapped address group.
Verify selected interface/gateway/source, reply path, unchanged primary management
access, a second apply, and cleanup. For persistence, repeat after a separately
approved reboot; neither script reboots the VM.

## Known Issues

### Older iproute2 Rejects `-N`

Outdated copies can stop during discovery with:

```text
Option "-N" is unknown, try "ip -help".
ERROR: Cannot read routes.
```

Older iproute2 versions do not recognize the numeric-name output option used by those copies.
This failure is not evidence of a bad gateway or an Azure connectivity problem.

The current Linux script uses portable `ip -4 -o route show ...` commands without `-N` for discovery, verification and cleanup. Numeric and standard named protocol/scope values are accepted. Strict cloud-policy validation normalizes only known aliases (`static`, `link`, `main`, `local`); unknown auxiliary-table aliases and unexpected route fields still require review. Failed route reads remain fatal.
No package upgrade, new dependency or networking restart is required by this fix.


### Runtime-Only NetworkManager Profiles

An image can have a working active NetworkManager connection whose profile lives
only under `/run/NetworkManager/system-connections/`. Runtime routes can work,
while `--persist` preview/apply fails with `Persistence requires a disk-backed profile under /etc`. The accompanying `PROFILE:` line reports the interface, UUID and path; the script does not copy, save or reactivate the profile.

Start with read-only inspection of the selected interface and profile storage:

```bash
interface='<TARGET_INTERFACE>'
nmcli --escape no -g GENERAL.CON-UUID device show "$interface"
nmcli --terse --escape no -f UUID,FILENAME connection show
ip -4 route show table main default

profile_uuid='<ACTIVE_PROFILE_UUID_FROM_OUTPUT>'
sudo nmcli --fields connection,ipv4 connection show uuid "$profile_uuid"
```

Identify the image/vendor configuration owner before preparing persistence.
`/run` may be intentional output from Netplan, cloud-init or another generator; do not blindly copy generated files into `/etc` or persist them with NetworkManager. Resolve externally managed configuration through its authoritative owner instead.

For a reviewed native NetworkManager profile only, when the owner agrees it should persist and `connection.autoconnect` is **already** `yes`, a normal modify can request a persistent save without changing that property's value:

```bash
interface=eth1
profile_uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$interface")
sudo nmcli connection modify uuid "$profile_uuid" connection.autoconnect yes
```

This is manual preparation, not a script option. It saves the **whole profile** and changes boot configuration, although it does not request activation/reapply.
Do not enable autoconnect merely to pass this check if it was previously disabled.
Do not restart NetworkManager or bring the connection down/up for this workflow.
Route rollback/reset does not undo profile preparation or delete profiles.

Repeat the read-only inspection above. Confirm the same active UUID, a filename under `/etc`, unchanged settings and the unchanged primary default route. Depending on the installed NetworkManager storage backend, the file may be a keyfile under `/etc/NetworkManager/system-connections/` or an ifcfg file under `/etc/sysconfig/network-scripts/`; do not install legacy network-scripts for this.
Then retry your original `--persist` command **without `--apply`** and review the plan before applying. Verify reboot behavior separately with recovery access.

### Other Diagnostics And Expected States

| Symptom                                                                              | Meaning And Safe Next Step                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Missing filename, `matches=0`, duplicate UUID matches, or storage lookup failure   | Persistent ownership is not established. Inspect the active UUID and native `UUID,FILENAME` listing, permissions and configuration owner. Missing/ambiguous records are not a reason to run the preparation command above. Storage outside `/etc` is also refused. |
| Autoconnect disabled, user-restricted profile, or unsupported/unreadable IPv4 method | Boot activation or route serialization cannot be guaranteed. Review intended settings with the image owner; the script will not silently change them.                                                                                                                  |
| Unsupported source-policy rules or auxiliary tables                                  | Only ordinary rules and the strictly validated cloud-policy layout in [Existing Cloud Policy](#existing-cloud-policy) are accepted. Do not delete rules or disable `nm-cloud-setup` to make validation pass.                                                          |
| Protected Netplan/networkd files block a non-root preview                            | Retry the same read-only command with `sudo`, still without `--apply`. Do not loosen file permissions or ownership.                                                                                                                                                |
| Unsupported/ambiguous backend ownership, renderer, or networkd drop-ins              | Tool availability alone does not establish ownership. Review the active configuration; native networkd without Netplan, ifupdown, wicked and Netplan's NetworkManager renderer are not implemented. Do not switch managers to bypass a refusal.                        |
| Saved-route collision or matching external Netplan routes block cleanup              | Existing configuration is not silently adopted or rewritten. Inspect its owner and metric. Preview metric-based rollback only for eligible script-owned routes; external routes need owner-reviewed cleanup. Never flush tables or delete profiles.                    |
| State changes during apply/cleanup                                                   | Concurrent configuration changes stop the operation. Earlier changes may remain; inspect current saved/live routes and review recovery from a console before retrying.                                                                                                 |
| A selector matches no NIC                                                            | The map warns and skips; all-skipped is a successful no-op. Check intended selectors and the actual assigned addresses. Invalid CIDRs and ambiguous/overlapping maps remain errors.                                                                                    |
| A DHCP route has no `src` after reboot                                             | Expected for saved DHCP routes, which omit a fixed preferred source to avoid boot ordering failures. Verify interface/gateway/source selection and source-bound connectivity separately; destination routes do not guarantee arbitrary-source symmetry.                |

## Tests

The isolated suites cover 218 Linux checks and 92 Windows checks per PowerShell
engine, including discovery, route conflicts, supported backends, persistence,
idempotency and cleanup. Native Netplan compilation checks skip explicitly when
the required compiler is absent.

Run from the repository root. The Linux runner covers the single multi-distro
implementation; the Windows runner runs under both supported PowerShell engines.

```bash
bash -n linux/azure-nic-routes.sh
bash -n tests/test-linux.sh
bash tests/test-linux.sh
```

```powershell
powershell.exe -NoProfile -NonInteractive -File tests/test-windows.ps1
pwsh -NoProfile -File tests/test-windows.ps1
```

Also parse the Windows script and test runner with both engines. Use ShellCheck
only when already installed. Fixtures mock networking; native Netplan compilation
uses temporary directories. These checks do not certify guest connectivity, backend
reactivation or reboot behavior. No packages are installed or workstation routes
changed. If WSL startup removes `/tmp`, use
`TMPDIR=/var/tmp bash tests/test-linux.sh`.

## References

- [Netplan configuration IDs](https://netplan.readthedocs.io/en/stable/structure-id/)
- [NetworkManager 1.40 nmcli connection modification and persistent saving](https://networkmanager.dev/docs/api/1.40.0/nmcli.html)
- [NetworkManager cloud policy layout and lifecycle](https://networkmanager.dev/docs/api/latest/nm-cloud-setup.html)
- [Upstream cloud setup preserving saved profile routes](https://github.com/NetworkManager/NetworkManager/blob/main/src/nm-cloud-setup/main.c)
- [Azure Linux multiple NICs](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/multiple-nics)
- [Azure Windows guest NIC configuration](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/multiple-nics#configure-guest-os-for-multiple-nics)
- [Azure subnet gateway reservation and supported prefix sizes](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-faq#configuration)
- [New-NetRoute stores and metric type](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netroute?view=windowsserver2022-ps)
- [Remove-NetRoute exact route/store selection](https://learn.microsoft.com/en-us/powershell/module/nettcpip/remove-netroute?view=windowsserver2022-ps)
- [PowerShell 7 native Windows module compatibility](https://learn.microsoft.com/en-us/powershell/windows/module-compatibility?view=windowsserver2022-ps)
