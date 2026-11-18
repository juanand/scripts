---
description: "PowerShell Azure Bastion tunnel connection script."
---
# Azure Bastion Tunnels

[Connect-AzBastionTunnel.ps1](Connect-AzBastionTunnel.ps1) starts an Azure CLI Bastion tunnel for Windows clients that runs `ssh.exe` or `mstsc.exe` against a loopback port. See the [user guide](README.md) for examples.

## Connection Contract

* Accept exactly one of `-TargetResourceId` and `-TargetIpAddress`. Bastion must be able to reach an IP target; reachability from the local workstation is not a prerequisite or a routing decision.
* Require `-BastionSubscription`, `-BastionName`, and `-BastionResourceGroup` without defaults. Accept a subscription name or ID. Use placeholders instead of internal resource identifiers and IPs in examples.
* Require `-Protocol` (`SSH` or `RDP`); default the remote port to 22 or 3389 respectively and honor `-VmPort` when supplied. Keep SSH interactive and support an optional `-SshKey` path.
* Use an OS-assigned ephemeral local port of at least 1024. Wait for the loopback listener with a bounded timeout and surface early Azure CLI failures before launching the client. A released port can be taken by another process, and a listening local port does not prove that the remote VM is reachable.
* Keep the tunnel alive while the client session is active. Verify process ownership on Windows, including CLI wrappers and RDP client handoff. Clean up only the tunnel process tree and its temporary logs on normal exit or failure, and provide actionable errors without exposing secrets.

## Verification

* Use the PowerShell parser (`System.Management.Automation.Language.Parser::ParseFile`) for a syntax check without executing the script. There is no build or test suite in this workspace.
* Check both target parameter sets, default and custom remote ports, SSH key paths with spaces, startup failure and timeout, and cleanup after the client exits. Prefer local stubs for process checks; do not treat a syntax check as proof of end-to-end behavior.
* Run a live smoke test only with an approved Azure subscription and target. Confirm authentication, Bastion native client support, and IP-based connection support when applicable. Distinguish VM reachability and client authentication issues from tunnel startup failures. See the [Azure CLI Bastion tunnel reference](https://learn.microsoft.com/en-us/cli/azure/network/bastion#az-network-bastion-tunnel).
