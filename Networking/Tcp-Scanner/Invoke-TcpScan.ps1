<#
.SYNOPSIS
Tests TCP handshakes against IPv4 hosts and ports.
.DESCRIPTION
Status is Open (handshake completed), Closed (refused/reset) or Filtered (timeout or unreachable).
By default, displays progress and streams completed results. Result order is not guaranteed.
With -OpenOnly, streams only successful connections and shows the latest open IP/port in progress.
With -Summarize (or --Summarize), returns IPAddress/OpenPorts rows at the end of the scan.
OpenPorts is a sorted, comma-separated list. IPs without open ports are omitted.
-OpenOnly and -Summarize cannot be combined.
Scans above 10000 host/port combinations require -Force.
Only scan networks you are authorized to test.
.EXAMPLE
.\Invoke-TcpScan.ps1 -Target 10.0.0.1 -Port 443
.EXAMPLE
.\Invoke-TcpScan.ps1 -Target 10.0.0.0/28 -Port 80-90,443 | Export-Csv scan.csv -NoTypeInformation
.EXAMPLE
.\Invoke-TcpScan.ps1 -Target 10.0.0.0/28 -Port 80,443 -Summarize
.EXAMPLE
.\Invoke-TcpScan.ps1 -Target 10.0.0.0/28 -Port 53 -OpenOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Target,

    [Parameter(Mandatory, Position = 1)]
    [string[]]$Port,

    [ValidateRange(1, 60000)]
    [int]$TimeoutMs = 500,

    [ValidateRange(1, 1024)]
    [int]$ThrottleLimit = 100,

    [switch]$IncludeNetworkAndBroadcast,

    [switch]$OpenOnly,

    [switch]$Summarize,

    [switch]$Force,

    [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
    [ValidateSet('--Summarize')]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest

# Above this many probes, Invoke-TcpScan requires -Force.
$script:ProbeLimit = 10000

function ConvertTo-PortList {
    <#
    .SYNOPSIS
    Expands port specs such as '443', '80,443', '80-90' or '22,80-90,443' into a sorted, de-duplicated list.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Port
    )

    $ports = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($item in $Port) {
        foreach ($token in ($item -split ',')) {
            $spec = $token.Trim()
            if ($spec -match '^(\d{1,5})-(\d{1,5})$') {
                $start = [int]$Matches[1]
                $end = [int]$Matches[2]
            }
            elseif ($spec -match '^\d{1,5}$') {
                $start = [int]$spec
                $end = $start
            }
            else {
                throw "Invalid port specification '$spec'. Use 443, 80,443 or 80-90."
            }

            if ($start -lt 1 -or $end -gt 65535) {
                throw "Port '$spec' is outside the range 1-65535."
            }
            if ($start -gt $end) {
                throw "Port range '$spec' has a start greater than its end."
            }
            for ($p = $start; $p -le $end; $p++) {
                [void]$ports.Add($p)
            }
        }
    }
    $ports
}

function ConvertTo-IPv4HostList {
    <#
    .SYNOPSIS
    Expands IPv4 addresses and CIDR blocks into de-duplicated host addresses.
    .DESCRIPTION
    /32 yields one host and /31 yields two. For /30 and larger networks the network and
    broadcast addresses are excluded unless -IncludeNetworkAndBroadcast is set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Target,

        [switch]$IncludeNetworkAndBroadcast,

        # Throws before enumerating if the total host count would exceed this value. 0 = no limit.
        [ValidateRange(0, [long]::MaxValue)]
        [long]$MaxCount = 0
    )

    $ranges = New-Object System.Collections.Generic.List[object]
    [uint64]$total = 0
    foreach ($item in $Target) {
        foreach ($token in ($item -split ',')) {
            $spec = $token.Trim()
            if ($spec -notmatch '^(?<ip>\d{1,3}(\.\d{1,3}){3})(/(?<prefix>\d{1,2}))?$') {
                throw "Invalid target '$spec'. Use an IPv4 address (10.0.0.1) or CIDR block (10.0.0.0/28)."
            }
            $address = $null
            if (-not [System.Net.IPAddress]::TryParse($Matches['ip'], [ref]$address)) {
                throw "Invalid IPv4 address in target '$spec'."
            }
            $prefix = 32
            if ($Matches['prefix']) {
                $prefix = [int]$Matches['prefix']
            }
            if ($prefix -gt 32) {
                throw "Invalid prefix length in target '$spec'. Use 0-32."
            }

            $bytes = $address.GetAddressBytes()
            if ([BitConverter]::IsLittleEndian) {
                [Array]::Reverse($bytes)
            }
            [uint64]$value = [BitConverter]::ToUInt32($bytes, 0)
            [uint64]$size = [uint64]1 -shl (32 - $prefix)
            [uint64]$first = $value - ($value % $size)
            [uint64]$last = $first + $size - 1
            if ($prefix -le 30 -and -not $IncludeNetworkAndBroadcast) {
                $first++
                $last--
            }

            $total += $last - $first + 1
            if ($MaxCount -gt 0 -and $total -gt $MaxCount) {
                throw "Targets expand to more than $MaxCount hosts."
            }
            $ranges.Add(@($first, $last))
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[uint32]'
    foreach ($range in $ranges) {
        for ([uint64]$i = $range[0]; $i -le $range[1]; $i++) {
            if (-not $seen.Add([uint32]$i)) {
                continue
            }
            $hostBytes = [BitConverter]::GetBytes([uint32]$i)
            if ([BitConverter]::IsLittleEndian) {
                [Array]::Reverse($hostBytes)
            }
            (New-Object System.Net.IPAddress (, $hostBytes)).ToString()
        }
    }
}

# Runs inside a runspace, so it must be self-contained.
$script:ProbeScript = {
    param([string]$IPAddress, [int]$Port, [int]$TimeoutMs)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        # SIO_TCP_INITIAL_RTO with no SYN retransmissions; otherwise Windows retries after RST and Closed takes ~2s.
        [void]$client.Client.IOControl(-1744830447, [byte[]](0xFF, 0xFF, 0xFE, 0x00), $null)
    }
    catch {
        Write-Debug "SIO_TCP_INITIAL_RTO not supported: $($_.Exception.Message)"
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'Filtered'
    try {
        $task = $client.ConnectAsync([System.Net.IPAddress]::Parse($IPAddress), $Port)
        if ($task.Wait($TimeoutMs)) {
            $status = 'Open'
        }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) {
            $inner = $inner.InnerException
        }
        if ($inner -is [System.Net.Sockets.SocketException] -and
            ($inner.SocketErrorCode -eq 'ConnectionRefused' -or $inner.SocketErrorCode -eq 'ConnectionReset')) {
            $status = 'Closed'
        }
    }
    finally {
        $stopwatch.Stop()
        $client.Dispose()
    }

    [PSCustomObject]@{
        IPAddress = $IPAddress
        Port      = $Port
        Status    = $status
        LatencyMs = [int]$stopwatch.Elapsed.TotalMilliseconds
    }
}

function Invoke-TcpScan {
    <#
    .SYNOPSIS
    Tests TCP handshakes against IPv4 hosts and ports.
    .DESCRIPTION
    Status is Open (handshake completed), Closed (refused/reset) or Filtered (timeout or unreachable).
    By default, displays progress and streams completed results. Result order is not guaranteed.
    With -OpenOnly, streams only successful connections and shows the latest open IP/port in progress.
    With -Summarize (or --Summarize), returns IPAddress/OpenPorts rows at the end of the scan.
    OpenPorts is a sorted, comma-separated list. IPs without open ports are omitted.
    -OpenOnly and -Summarize cannot be combined.
    Scans above 10000 host/port combinations require -Force.
    Only scan networks you are authorized to test.
    .EXAMPLE
    Invoke-TcpScan -Target 10.0.0.0/28 -Port 80-90,443 | Where-Object Status -eq 'Open'
    .EXAMPLE
    Invoke-TcpScan -Target 10.0.0.0/28 -Port 80,443 -Summarize
    .EXAMPLE
    Invoke-TcpScan -Target 10.0.0.0/28 -Port 53 -OpenOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Target,

        [Parameter(Mandatory, Position = 1)]
        [string[]]$Port,

        [ValidateRange(1, 60000)]
        [int]$TimeoutMs = 500,

        [ValidateRange(1, 1024)]
        [int]$ThrottleLimit = 100,

        [switch]$IncludeNetworkAndBroadcast,

        [switch]$OpenOnly,

        [switch]$Summarize,

        # Allows scans above the probe limit.
        [switch]$Force,

        [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
        [ValidateSet('--Summarize')]
        [string[]]$RemainingArguments
    )

    if ($RemainingArguments) {
        $Summarize = $true
    }
    if ($OpenOnly -and $Summarize) {
        throw 'The -OpenOnly and -Summarize switches cannot be combined. Use -OpenOnly for live results or -Summarize for a final summary.'
    }

    $ports = @(ConvertTo-PortList -Port $Port)
    $maxHosts = 0
    if (-not $Force) {
        if ($ports.Count -gt $script:ProbeLimit) {
            throw "Scan exceeds $($script:ProbeLimit) probes. Narrow the targets or ports, or use -Force."
        }
        $maxHosts = [Math]::Floor($script:ProbeLimit / $ports.Count)
    }
    try {
        $hosts = @(ConvertTo-IPv4HostList -Target $Target -IncludeNetworkAndBroadcast:$IncludeNetworkAndBroadcast -MaxCount $maxHosts)
    }
    catch {
        if ($maxHosts -gt 0 -and $_.Exception.Message -like 'Targets expand to more than*') {
            throw "Scan exceeds $($script:ProbeLimit) probes. Narrow the targets or ports, or use -Force."
        }
        throw
    }
    Write-Verbose "Scanning $($hosts.Count) host(s) x $($ports.Count) port(s) with timeout ${TimeoutMs}ms and throttle $ThrottleLimit."

    [long]$totalProbes = [long]$hosts.Count * $ports.Count
    [long]$scheduledCount = 0
    [long]$completedCount = 0
    [long]$openCount = 0
    [long]$reportedOpenCount = 0
    $lastOpenEndpoint = $null
    $openPorts = @{}
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
    $jobs = New-Object System.Collections.Generic.List[object]
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressMs = 0
    $progress = @{
        Id               = 1
        Activity         = 'TCP scan'
        Status           = "0 of $totalProbes probes completed"
        CurrentOperation = "Starting $($hosts[0]):$($ports[0]); $($hosts.Count) host(s) x $($ports.Count) port(s)"
        PercentComplete  = 0
    }
    if ($OpenOnly) {
        $progress.Status += '; 0 open'
        $progress.CurrentOperation = 'Waiting for an open TCP connection'
    }
    try {
        Write-Progress @progress
        $pool.Open()
        while ($completedCount -lt $totalProbes) {
            while ($jobs.Count -lt $ThrottleLimit -and $scheduledCount -lt $totalProbes) {
                $hostIndex = [int][Math]::Floor($scheduledCount / $ports.Count)
                $portIndex = [int]($scheduledCount % $ports.Count)
                $ipAddress = $hosts[$hostIndex]
                $portNumber = $ports[$portIndex]
                $powerShell = [PowerShell]::Create().AddScript($script:ProbeScript).AddArgument($ipAddress).AddArgument($portNumber).AddArgument($TimeoutMs)
                try {
                    $powerShell.RunspacePool = $pool
                    $handle = $powerShell.BeginInvoke()
                    $jobs.Add([PSCustomObject]@{
                        PowerShell = $powerShell
                        Handle     = $handle
                        IPAddress  = $ipAddress
                        Port       = $portNumber
                    })
                }
                catch {
                    $powerShell.Dispose()
                    throw
                }
                $scheduledCount++
            }

            $completedBefore = $completedCount
            for ($jobIndex = $jobs.Count - 1; $jobIndex -ge 0; $jobIndex--) {
                $job = $jobs[$jobIndex]
                if ($job.Handle.IsCompleted) {
                    try {
                        $probeResults = $job.PowerShell.EndInvoke($job.Handle)
                        if ($Summarize) {
                            foreach ($result in $probeResults) {
                                if ($result.Status -eq 'Open') {
                                    if (-not $openPorts.ContainsKey($result.IPAddress)) {
                                        $openPorts[$result.IPAddress] = New-Object 'System.Collections.Generic.SortedSet[int]'
                                    }
                                    [void]$openPorts[$result.IPAddress].Add([int]$result.Port)
                                }
                            }
                        }
                        elseif ($OpenOnly) {
                            foreach ($result in $probeResults) {
                                if ($result.Status -eq 'Open') {
                                    $openCount++
                                    $lastOpenEndpoint = "$($result.IPAddress):$($result.Port)"
                                    $result
                                }
                            }
                        }
                        else {
                            $probeResults
                        }
                    }
                    finally {
                        $job.Handle.AsyncWaitHandle.Dispose()
                        $job.PowerShell.Dispose()
                        $jobs.RemoveAt($jobIndex)
                    }
                    $completedCount++
                }
            }

            if ($stopwatch.ElapsedMilliseconds - $lastProgressMs -ge 250 -or
                $completedCount -eq $totalProbes -or ($OpenOnly -and $openCount -gt $reportedOpenCount)) {
                $progress.Status = "$completedCount of $totalProbes probes completed; $($jobs.Count) in flight"
                $progress.PercentComplete = [int][Math]::Floor(100.0 * $completedCount / $totalProbes)
                if ($OpenOnly) {
                    $progress.Status += "; $openCount open"
                    if ($lastOpenEndpoint) {
                        $progress.CurrentOperation = "Last open: $lastOpenEndpoint"
                    }
                }
                elseif ($jobs.Count -gt 0) {
                    $progress.CurrentOperation = "Probing $($jobs[0].IPAddress):$($jobs[0].Port)"
                }
                elseif ($scheduledCount -lt $totalProbes) {
                    $progress.CurrentOperation = 'Scheduling more probes'
                }
                else {
                    $progress.CurrentOperation = 'Finishing scan'
                }
                Write-Progress @progress
                $lastProgressMs = $stopwatch.ElapsedMilliseconds
                $reportedOpenCount = $openCount
            }

            if ($completedCount -eq $completedBefore -and $jobs.Count -gt 0) {
                [void]$jobs[0].Handle.AsyncWaitHandle.WaitOne(25)
            }
        }
    }
    finally {
        $stopwatch.Stop()
        try {
            foreach ($job in $jobs) {
                $job.PowerShell.Stop()
                $job.Handle.AsyncWaitHandle.Dispose()
                $job.PowerShell.Dispose()
            }
            $pool.Dispose()
        }
        finally {
            Write-Progress -Id 1 -Activity 'TCP scan' -Completed
        }
    }

    if ($Summarize) {
        foreach ($ipAddress in $hosts) {
            if ($openPorts.ContainsKey($ipAddress)) {
                [PSCustomObject]@{
                    IPAddress = $ipAddress
                    OpenPorts = $openPorts[$ipAddress] -join ', '
                }
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-TcpScan @PSBoundParameters
}
 