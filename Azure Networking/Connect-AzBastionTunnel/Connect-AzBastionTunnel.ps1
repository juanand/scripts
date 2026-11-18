<#
.SYNOPSIS
Connects to an Azure VM over SSH or Remote Desktop through Azure Bastion.

.DESCRIPTION
Starts an Azure CLI Bastion tunnel on an OS-assigned local TCP port of at least
1024, then opens the Windows SSH or Remote Desktop client. The script stops the
tunnel when the client exits. Sign in to Azure CLI before running the script.

Specify exactly one of TargetResourceId and TargetIpAddress. IP-based connections
must be enabled on the Bastion host. Bastion must be able to reach the VM, but
your workstation does not need a direct route to it.

.PARAMETER TargetResourceId
Full Azure resource ID of the target VM. Cannot be combined with TargetIpAddress.

.PARAMETER TargetIpAddress
IP address of the target VM as reachable from Bastion. Cannot be combined with
TargetResourceId.

.PARAMETER Protocol
Client protocol: SSH or RDP.

.PARAMETER BastionSubscription
Name or ID of the subscription that contains the Bastion host.

.PARAMETER BastionName
Name of the Bastion host.

.PARAMETER BastionResourceGroup
Resource group that contains the Bastion host, not necessarily the target VM.

.PARAMETER VmPort
Remote port on the VM. Defaults to 22 for SSH and 3389 for RDP. This does not
change the local tunnel port.

.PARAMETER Username
VM username. Required for SSH and optional for RDP. When omitted for RDP,
the script lets Remote Desktop choose its default.

.PARAMETER SshKey
Path to an SSH private key. Quote paths containing spaces. If omitted, OpenSSH
uses its normal authentication settings.

.PARAMETER SshOptions
Additional arguments passed to ssh.exe as an array, such as
@('-o', 'ServerAliveInterval=30').

.PARAMETER RdpOptions
Additional arguments passed to mstsc.exe as an array, such as @('/f').

.PARAMETER TunnelStartupTimeoutSeconds
Seconds to wait for the local tunnel to become ready. Defaults to 45. Valid
values are 5 through 300.

.EXAMPLE
.\Connect-AzureBastion.ps1 -Protocol SSH -TargetIpAddress '192.0.2.10' -Username 'vmuser' `
    -BastionSubscription 'Example Subscription' -BastionName 'example-bastion' `
    -BastionResourceGroup 'example-network-rg'

Starts an interactive SSH connection by IP. OpenSSH prompts for a VM password
if no key succeeds and the VM allows password authentication.

.EXAMPLE
$vmId = '/subscriptions/<vm-subscription-id>/resourceGroups/<vm-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>'
.\Connect-AzureBastion.ps1 -Protocol RDP -TargetResourceId $vmId `
    -BastionSubscription 'Example Subscription' -BastionName 'example-bastion' `
    -BastionResourceGroup 'example-network-rg'

Opens Remote Desktop to the VM identified by its resource ID. Replace the
placeholders in the resource ID with your VM details.

.LINK
https://learn.microsoft.com/en-us/cli/azure/network/bastion#az-network-bastion-tunnel
#>

[CmdletBinding(DefaultParameterSetName = 'ResourceId')]
param(
    # -------------------------------------------------------------------------
    # Target: specify either a VM resource ID or an IP address
    # -------------------------------------------------------------------------

    [Parameter(
        Mandatory = $true,
        ParameterSetName = 'ResourceId',
        HelpMessage = 'Azure resource ID of the target VM.'
    )]
    [ValidateNotNullOrEmpty()]
    [string]$TargetResourceId,

    [Parameter(
        Mandatory = $true,
        ParameterSetName = 'IpAddress',
        HelpMessage = 'IP address reachable from the Azure Bastion virtual network.'
    )]
    [ValidateNotNullOrEmpty()]
    [string]$TargetIpAddress,

    # -------------------------------------------------------------------------
    # Connection settings
    # -------------------------------------------------------------------------

    [Parameter(Mandatory = $true)]
    [ValidateSet('SSH', 'RDP')]
    [string]$Protocol,

    # Defaults to 22 for SSH and 3389 for RDP.
    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$VmPort,

    [Parameter()]
    [string]$Username,

    # Optional SSH private-key file.
    [Parameter()]
    [string]$SshKey,

    # Additional arguments passed directly to ssh.exe.
    #
    # Example:
    # -SshOptions @(
    #     '-o', 'StrictHostKeyChecking=accept-new',
    #     '-o', 'ServerAliveInterval=30'
    # )
    [Parameter()]
    [string[]]$SshOptions = @(),

    # Additional arguments passed directly to mstsc.exe.
    #
    # Example:
    # -RdpOptions @('/f')
    [Parameter()]
    [string[]]$RdpOptions = @(),

    # -------------------------------------------------------------------------
    # Azure settings
    # -------------------------------------------------------------------------

    [Parameter(Mandatory = $true, HelpMessage = 'Name or ID of the subscription that contains the Bastion host.')]
    [ValidateNotNullOrEmpty()]
    [string]$BastionSubscription,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BastionName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BastionResourceGroup,

    # Maximum time to wait for the local Bastion tunnel to start.
    [Parameter()]
    [ValidateRange(5, 300)]
    [int]$TunnelStartupTimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-EphemeralTcpPort {
    [CmdletBinding()]
    param()

    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )

    try {
        $listener.Start()

        $localEndpoint = [System.Net.IPEndPoint]$listener.LocalEndpoint
        if ($localEndpoint.Port -lt 1024) {
            throw 'Windows assigned a local TCP port below 1024. Check the Windows dynamic TCP port range.'
        }

        return $localEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Test-TunnelListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1024, 65535)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$TunnelProcess
    )

    $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' `
        -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $listener -or $TunnelProcess.HasExited) {
        return $false
    }

    $ownerId = $listener.OwningProcess
    while ($ownerId -gt 0) {
        if ($ownerId -eq $TunnelProcess.Id) {
            return (-not $TunnelProcess.HasExited)
        }

        $owner = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ownerId"
        if (-not $owner -or $owner.CreationDate -lt $TunnelProcess.StartTime -or
            $owner.ParentProcessId -eq $ownerId) {
            break
        }

        $ownerId = $owner.ParentProcessId
    }

    throw "Port 127.0.0.1:$Port is owned by a different process. Rerun to select a new port."
}

function Stop-ProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Id
    )

    # Azure CLI on Windows can involve az.cmd, cmd.exe, and child processes.
    # /T terminates the complete child-process tree.
    & taskkill.exe /PID $Id /T /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "taskkill failed for tunnel PID $Id (exit code $LASTEXITCODE)."
    }
}

function Get-LogContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw
    }

    return ''
}

function Start-BastionProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$StdoutPath,

        [Parameter(Mandatory = $true)]
        [string]$StderrPath
    )

    foreach ($value in (@($Executable) + $Arguments)) {
        if ($value -match '["%\x00-\x1f]' -or $value.EndsWith('\')) {
            throw 'The Azure CLI path or a tunnel argument contains unsupported characters.'
        }
    }

    $argumentLine = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    if ([IO.Path]::GetExtension($Executable) -in '.cmd', '.bat') {
        $argumentLine = '/d /v:off /s /c ""' + $Executable + '" ' + $argumentLine + '"'
        $Executable = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    }

    Start-Process -FilePath $Executable -ArgumentList $argumentLine `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath `
        -WindowStyle Hidden -PassThru
}

# -----------------------------------------------------------------------------
# Resolve protocol-specific defaults
# -----------------------------------------------------------------------------

if (-not $PSBoundParameters.ContainsKey('VmPort')) {
    if ($Protocol -eq 'SSH') {
        $VmPort = 22
    }
    else {
        $VmPort = 3389
    }
}

# -----------------------------------------------------------------------------
# Validate local prerequisites
# -----------------------------------------------------------------------------

$azCommand = Get-Command 'az' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -eq $azCommand) {
    throw @'
Azure CLI was not found in PATH.

Install Azure CLI or add az.exe/az.cmd to PATH. Then start a new PowerShell
session and run:

    az login
'@
}

switch ($Protocol) {
    'SSH' {
        $sshCommand = Get-Command 'ssh.exe' -ErrorAction SilentlyContinue

        if ($null -eq $sshCommand) {
            throw @'
The Windows OpenSSH client, ssh.exe, was not found.

Install the Windows OpenSSH Client optional feature and start a new
PowerShell session.
'@
        }

        if ([string]::IsNullOrWhiteSpace($Username)) {
            throw 'Specify -Username for an SSH connection.'
        }

        if (-not [string]::IsNullOrWhiteSpace($SshKey)) {
            $resolvedKey = Resolve-Path `
                -LiteralPath $SshKey `
                -ErrorAction Stop
            $SshKey = $resolvedKey.ProviderPath

            if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) {
                throw "The SSH key path is not a file: $SshKey"
            }
        }
    }

    'RDP' {
        $mstscCommand = Get-Command 'mstsc.exe' `
            -ErrorAction SilentlyContinue

        if ($null -eq $mstscCommand) {
            throw @'
The Windows Remote Desktop client, mstsc.exe, was not found.
'@
        }
    }
}

# -----------------------------------------------------------------------------
# Initialize runtime variables
# -----------------------------------------------------------------------------

$localPort = Get-EphemeralTcpPort
$tunnelProcess = $null
$clientExitCode = 0

$logIdentifier = [guid]::NewGuid().ToString('N')

$stdoutLog = Join-Path `
    -Path $env:TEMP `
    -ChildPath "azure-bastion-$logIdentifier.stdout.log"

$stderrLog = Join-Path `
    -Path $env:TEMP `
    -ChildPath "azure-bastion-$logIdentifier.stderr.log"

try {
    # -------------------------------------------------------------------------
    # Display connection settings
    # -------------------------------------------------------------------------

    Write-Host ''
    Write-Host 'Azure Bastion connection' -ForegroundColor Cyan
    Write-Host '------------------------' -ForegroundColor Cyan
    Write-Host "Bastion subscription: $BastionSubscription" -ForegroundColor DarkGray
    Write-Host "Bastion:      $BastionName" -ForegroundColor DarkGray
    Write-Host "Bastion RG:   $BastionResourceGroup" -ForegroundColor DarkGray
    Write-Host "Protocol:     $Protocol" -ForegroundColor DarkGray
    Write-Host "VM port:      $VmPort" -ForegroundColor DarkGray
    Write-Host ''

    # -------------------------------------------------------------------------
    # Build the Azure Bastion tunnel command
    # -------------------------------------------------------------------------

    $tunnelArguments = @(
        'network'
        'bastion'
        'tunnel'
        '--name'
        $BastionName
        '--resource-group'
        $BastionResourceGroup
        '--subscription'
        $BastionSubscription
    )

    if ($PSCmdlet.ParameterSetName -eq 'ResourceId') {
        $tunnelArguments += @(
            '--target-resource-id'
            $TargetResourceId
        )

        $targetDescription = $TargetResourceId
    }
    else {
        $tunnelArguments += @(
            '--target-ip-address'
            $TargetIpAddress
        )

        $targetDescription = $TargetIpAddress
    }

    $tunnelArguments += @(
        '--resource-port'
        $VmPort.ToString()
        '--port'
        $localPort.ToString()
        '--only-show-errors'
    )

    Write-Host 'Starting the Azure Bastion tunnel...' -ForegroundColor Cyan
    Write-Host "Target:       $targetDescription" -ForegroundColor DarkGray
    Write-Host "Remote port:  $VmPort" -ForegroundColor DarkGray
    Write-Host "Local tunnel: 127.0.0.1:$localPort" -ForegroundColor DarkGray
    Write-Host ''

    # Start Azure CLI in the background because the command remains active for
    # the complete lifetime of the tunnel.
    $tunnelProcess = Start-BastionProcess -Executable $azCommand.Source `
        -Arguments $tunnelArguments -StdoutPath $stdoutLog -StderrPath $stderrLog

    # -------------------------------------------------------------------------
    # Wait for the local end of the Bastion tunnel
    # -------------------------------------------------------------------------

    $startupTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $tunnelReady = $false

    do {
        $tunnelProcess.Refresh()

        if ($tunnelProcess.HasExited) {
            $stderrContent = Get-LogContent -Path $stderrLog
            $stdoutContent = Get-LogContent -Path $stdoutLog

            throw @"
Azure CLI exited before the Bastion tunnel was established.
Check Azure CLI sign-in, subscription access, and Bastion native client settings.

Exit code:
$($tunnelProcess.ExitCode)

Standard error:
$stderrContent

Standard output:
$stdoutContent
"@
        }

        $tunnelReady = Test-TunnelListener -Port $localPort -TunnelProcess $tunnelProcess
        if (-not $tunnelReady -and $startupTimer.Elapsed.TotalSeconds -lt $TunnelStartupTimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    }
    until (
        $tunnelReady -or
        $startupTimer.Elapsed.TotalSeconds -ge $TunnelStartupTimeoutSeconds
    )

    if (-not $tunnelReady) {
        $stderrContent = Get-LogContent -Path $stderrLog
        $stdoutContent = Get-LogContent -Path $stdoutLog

        throw @"
Timed out after $TunnelStartupTimeoutSeconds seconds while waiting for the
Azure Bastion tunnel on 127.0.0.1:$localPort.

Standard error:
$stderrContent

Standard output:
$stdoutContent
"@
    }

    Write-Host "Tunnel ready on 127.0.0.1:$localPort" `
        -ForegroundColor Green

    Write-Host ''

    # -------------------------------------------------------------------------
    # Start the requested client
    # -------------------------------------------------------------------------

    if ($Protocol -eq 'SSH') {
        # SSH options must appear before the destination. Arguments placed
        # after the destination can be interpreted as a remote command.
        $sshArguments = @(
            '-p'
            $localPort.ToString()
        )

        if (-not [string]::IsNullOrWhiteSpace($SshKey)) {
            $sshArguments += @(
                '-i'
                $SshKey
            )
            Write-Host "SSH key file: $SshKey" -ForegroundColor DarkGray
        }

        if ($SshOptions.Count -gt 0) {
            $sshArguments += $SshOptions
        }

        $hostKeyIdentity = if ($PSCmdlet.ParameterSetName -eq 'ResourceId') {
            @('vm', $TargetResourceId)
        }
        else {
            @('ip', $BastionSubscription, $BastionResourceGroup, $BastionName, $TargetIpAddress)
        }
        $identityJson = ConvertTo-Json -InputObject $hostKeyIdentity -Compress
        $identityBytes = [System.Text.Encoding]::UTF8.GetBytes($identityJson.ToLowerInvariant())
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $identityHash = [System.BitConverter]::ToString($sha256.ComputeHash($identityBytes)).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
        $hostKeyAlias = 'azure-bastion-' + $identityHash.ToLowerInvariant()
        $sshArguments += @(
            '-o', "HostKeyAlias=$hostKeyAlias"
            '-o', 'CheckHostIP=no'
            '-l', $Username, '--', '127.0.0.1'
        )

        Write-Host "Starting SSH connection as '$Username'..." `
            -ForegroundColor Cyan

        # Execute SSH in the current console. This preserves interactive
        # password prompts, private-key passphrase prompts, and terminal input.
        & ssh.exe @sshArguments

        $clientExitCode = $LASTEXITCODE

        if ($clientExitCode -ne 0) {
            Write-Warning "SSH exited with code $clientExitCode."
        }
    }
    else {
        $rdpEndpoint = "127.0.0.1:$localPort"
        $rdpFile = $null
        try {
            if ($PSBoundParameters.ContainsKey('Username')) {
                if ([string]::IsNullOrWhiteSpace($Username) -or $Username -match '[\x00-\x1f]') {
                    throw 'RDP username must be nonempty and cannot contain control characters.'
                }

                $rdpFile = Join-Path ([IO.Path]::GetTempPath()) "azure-bastion-$logIdentifier.rdp"
                Set-Content -LiteralPath $rdpFile -Encoding Unicode -Value @(
                    "full address:s:$rdpEndpoint"
                    "username:s:$Username"
                )
                $rdpArguments = @('"' + $rdpFile + '"')
            }
            else {
                $rdpArguments = @("/v:$rdpEndpoint")
            }

            if ($RdpOptions.Count -gt 0) {
                $rdpArguments += $RdpOptions
            }

            Write-Host 'Starting Remote Desktop...' -ForegroundColor Cyan
            Write-Host "RDP endpoint: $rdpEndpoint" -ForegroundColor DarkGray
            Write-Host ''

            $rdpProcess = Start-Process `
                -FilePath $mstscCommand.Source `
                -ArgumentList $rdpArguments `
                -Wait `
                -PassThru

            $clientExitCode = $rdpProcess.ExitCode
        }
        finally {
            if ($null -ne $rdpFile) {
                Remove-Item -LiteralPath $rdpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
catch {
    $clientExitCode = 1
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    # -------------------------------------------------------------------------
    # Always stop the Bastion tunnel
    # -------------------------------------------------------------------------

    if ($null -ne $tunnelProcess) {
        try {
            $tunnelProcess.Refresh()

            if (-not $tunnelProcess.HasExited) {
                Write-Host ''
                Write-Host 'Stopping the Azure Bastion tunnel...' `
                    -ForegroundColor Yellow

                Stop-ProcessTree -Id $tunnelProcess.Id
                if (-not $tunnelProcess.WaitForExit(5000)) {
                    throw 'The tunnel process did not exit after taskkill.'
                }
            }
        }
        catch {
            $clientExitCode = 1
            Write-Warning (
                'Could not completely stop the tunnel process. ' +
                $_.Exception.Message
            )
        }
    }

    Remove-Item `
        -LiteralPath $stdoutLog `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $stderrLog `
        -Force `
        -ErrorAction SilentlyContinue

}

exit $clientExitCode