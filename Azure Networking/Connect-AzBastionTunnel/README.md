---
description: "Connect to Azure VMs from Windows with PowerShell over SSH or Remote Desktop through Azure Bastion tunnel."
---
# Azure Bastion Tunnel Helper Script

[Connect-AzBastionTunnel.ps1](Connect-AzBastionTunnel.ps1) is a human-tested, vibe-coded script to simplify the user experience connecting to Linux or Windows VMs through Azure Bastion tunnels.

Run [Connect-AzBastionTunnel.ps1](Connect-AzBastionTunnel.ps1) from PowerShell on Windows to open a Bastion tunnel and start SSH or Remote Desktop in one single command. Windows assigns an ephemeral local port of at least `1024`, and the script stops the tunnel when the client exits.

## Prerequisites

* Install Azure CLI and sign in with `az login`. Use an account with access to the Bastion host and target VM as applicable.
* Enable native client support on a Bastion host that supports it. To target an IP address, also enable IP-based connections. Bastion must be able to reach the VM and its SSH or RDP port. Your Windows workstation does not need a direct route to the VM.
* Use Windows OpenSSH (`ssh.exe`) for SSH or Windows Remote Desktop (`mstsc.exe`) for RDP. The VM must have the corresponding service enabled and accept your credentials.

See the [Azure CLI Bastion tunnel reference](https://learn.microsoft.com/en-us/cli/azure/network/bastion#az-network-bastion-tunnel) for CLI options and prerequisites.

## Connect

From the script directory, set the three required Bastion parameters. `-BastionSubscription` accepts the name or ID of the subscription containing the Bastion host. `-BastionResourceGroup` is the resource group containing the Bastion host, not necessarily the one containing the VM.

```powershell
$bastion = @{
    BastionSubscription  = '<bastion-subscription-name-or-id>'
    BastionName         = '<bastion-name>'
    BastionResourceGroup = '<bastion-resource-group>'
}
```

Supply `-Protocol` and exactly one of `-TargetIpAddress` or `-TargetResourceId` on each call. Either target form works with either protocol. Replace all placeholders with your own values. Supply `-Username` for SSH. For RDP, it is optional.

### Linux SSH With a Password

```powershell
.\Connect-AzBastionTunnel.ps1 @bastion -Protocol SSH -TargetIpAddress '<vm-ip>' -Username '<vm-user>'
```

Enter the VM password at the SSH prompt when asked. Do not pass passwords on the command line.

### Linux SSH With a Private Key

```powershell
$vmId = '/subscriptions/<vm-subscription-id>/resourceGroups/<vm-resource-group>/providers/Microsoft.Compute/virtualMachines/<linux-vm-name>'
.\Connect-AzBastionTunnel.ps1 @bastion -Protocol SSH -TargetResourceId $vmId `
    -Username '<vm-user>' -SshKey 'C:\Users\Example User\.ssh\id_ed25519'
```

Use the private key whose public key is authorized for the VM user. Quote paths containing spaces. If you omit `-SshKey`, OpenSSH can still try keys from your SSH configuration, standard key paths, or `ssh-agent` before prompting for a password, if the VM allows password authentication.

### SSH Host Key Verification

An `azure-bastion-...` entry in `known_hosts` is expected. The script passes OpenSSH a stable alias that identifies the VM independently of the local tunnel port. OpenSSH checks the saved host key and can add an entry when you accept a new key. The script itself does not read, edit, or delete entries in `known_hosts`.

* With `-TargetIpAddress`, the alias depends on the target IP, Bastion subscription, resource group, and name. Different Bastions can reach different VMs at the same private IP, so they normally get separate entries. For the same Bastion, consistently use either its subscription name or its ID: switching between them can also produce a new alias.
* With `-TargetResourceId`, the alias depends on the VM resource ID, not on the Bastion. Using a different Bastion to reach that same VM reuses the saved entry.

Verify the host-key fingerprint against a trusted source before accepting it for a new alias. If two Bastions are meant to reach the same VM by IP, verify that they present the same fingerprint for the same key type. Once a key is saved, OpenSSH can warn if it changes on a later connection using that alias.

### Windows Remote Desktop

```powershell
.\Connect-AzBastionTunnel.ps1 @bastion -Protocol RDP -TargetIpAddress '<vm-ip>' `
  -Username 'EXAMPLE\vm-user'
```

`-Username` is optional. When supplied, the script passes it to Remote Desktop in a temporary connection file that is removed when the client exits. The script does not supply a password. Enter your Windows VM credentials when prompted. Close the Remote Desktop session window, or exit SSH, to stop the tunnel.

## Options

| Parameter                        | Default or behavior                                                                                                              |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `-VmPort`                      | Remote VM port: `22` for SSH or `3389` for RDP. Set it if the service uses a different port. It does not set the local port. |
| `-Username`                    | VM username. Required for SSH and optional for RDP. No script default.                                                           |
| `-SshKey`                      | Optional path to an SSH private key.                                                                                             |
| `-SshOptions`, `-RdpOptions` | Optional arrays of arguments for the corresponding client.                                                                       |
| `-TunnelStartupTimeoutSeconds` | Defaults to `45`; accepts `5` to `300` seconds.                                                                            |

Run `Get-Help .\Connect-AzBastionTunnel.ps1` for built-in help. Add `-Examples` or `-Full` for more detail.

## Troubleshooting

* If Azure CLI exits before the tunnel is ready, check the reported CLI error, Azure sign-in, subscription access, and Bastion native client or IP-based connection settings.
* If another process claims the assigned local port, rerun the command to get a new port.
* If the tunnel is ready but SSH or RDP cannot connect, check Bastion-to-VM reachability and the remote service port. If the client rejects authentication, check the VM username and credentials.
