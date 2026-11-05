BeforeAll {
    Get-Module TcpScanner | Remove-Module -Force
    $scannerPath = Join-Path $PSScriptRoot '..\Invoke-TcpScan.ps1'
    $scannerModule = New-Module -Name TcpScanner -ArgumentList $scannerPath -ScriptBlock {
        param($path)
        . $path -Target '127.0.0.1' -Port '1'
    }
    Import-Module $scannerModule -Force
}

AfterAll {
    Get-Module TcpScanner | Remove-Module -Force
}

Describe 'ConvertTo-PortList' {
    It 'parses a single port' {
        ConvertTo-PortList -Port '443' | Should -Be 443
    }

    It 'parses a comma-separated list' {
        ConvertTo-PortList -Port '80,443' | Should -Be @(80, 443)
    }

    It 'parses an array of ports' {
        ConvertTo-PortList -Port 443, 80 | Should -Be @(80, 443)
    }

    It 'expands a range' {
        ConvertTo-PortList -Port '80-90' | Should -Be (80..90)
    }

    It 'sorts and de-duplicates a mixed spec' {
        ConvertTo-PortList -Port '443, 22,80-82,81' | Should -Be @(22, 80, 81, 82, 443)
    }

    It 'accepts the boundary ports' {
        ConvertTo-PortList -Port '1,65535' | Should -Be @(1, 65535)
    }

    It 'rejects <Spec>' -TestCases @(
        @{ Spec = '0' }
        @{ Spec = '65536' }
        @{ Spec = '90-80' }
        @{ Spec = 'abc' }
        @{ Spec = '80-' }
        @{ Spec = '80,,443' }
        @{ Spec = '-1' }
        @{ Spec = '999999' }
    ) {
        { ConvertTo-PortList -Port $Spec } | Should -Throw
    }
}

Describe 'ConvertTo-IPv4HostList' {
    It 'returns a single address' {
        ConvertTo-IPv4HostList -Target '10.0.0.1' | Should -Be '10.0.0.1'
    }

    It 'returns one host for /32' {
        ConvertTo-IPv4HostList -Target '10.0.0.1/32' | Should -Be '10.0.0.1'
    }

    It 'returns two hosts for /31' {
        ConvertTo-IPv4HostList -Target '10.0.0.0/31' | Should -Be @('10.0.0.0', '10.0.0.1')
    }

    It 'excludes network and broadcast for /30' {
        ConvertTo-IPv4HostList -Target '10.0.0.0/30' | Should -Be @('10.0.0.1', '10.0.0.2')
    }

    It 'expands /28 to 14 hosts' {
        $hosts = @(ConvertTo-IPv4HostList -Target '10.0.0.0/28')
        $hosts.Count | Should -Be 14
        $hosts[0] | Should -Be '10.0.0.1'
        $hosts[-1] | Should -Be '10.0.0.14'
    }

    It 'normalizes a host address to its network' {
        ConvertTo-IPv4HostList -Target '10.0.0.5/28' | Should -Be (ConvertTo-IPv4HostList -Target '10.0.0.0/28')
    }

    It 'includes network and broadcast when requested' {
        $hosts = @(ConvertTo-IPv4HostList -Target '10.0.0.0/28' -IncludeNetworkAndBroadcast)
        $hosts.Count | Should -Be 16
        $hosts[0] | Should -Be '10.0.0.0'
        $hosts[-1] | Should -Be '10.0.0.15'
    }

    It 'crosses octet boundaries' {
        $hosts = @(ConvertTo-IPv4HostList -Target '10.0.0.0/23')
        $hosts.Count | Should -Be 510
        $hosts[0] | Should -Be '10.0.0.1'
        $hosts[-1] | Should -Be '10.0.1.254'
    }

    It 'handles the top of the address space' {
        ConvertTo-IPv4HostList -Target '255.255.255.254/31' | Should -Be @('255.255.255.254', '255.255.255.255')
    }

    It 'de-duplicates overlapping targets' {
        ConvertTo-IPv4HostList -Target '10.0.0.1', '10.0.0.0/30' | Should -Be @('10.0.0.1', '10.0.0.2')
    }

    It 'accepts comma-separated targets' {
        ConvertTo-IPv4HostList -Target '10.0.0.1,10.0.0.9' | Should -Be @('10.0.0.1', '10.0.0.9')
    }

    It 'throws when MaxCount is exceeded' {
        { ConvertTo-IPv4HostList -Target '10.0.0.0/16' -MaxCount 100 } | Should -Throw '*more than 100*'
    }

    It 'rejects <Spec>' -TestCases @(
        @{ Spec = '10.0.0.256' }
        @{ Spec = '10.0.0' }
        @{ Spec = '10.0.0.0/33' }
        @{ Spec = '10.0.0.0/' }
        @{ Spec = '10.0.0.0/-1' }
        @{ Spec = 'abc' }
        @{ Spec = 'fe80::1' }
    ) {
        { ConvertTo-IPv4HostList -Target $Spec } | Should -Throw
    }
}

Describe 'Invoke-TcpScan' {
    BeforeAll {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $openPort = $listener.LocalEndpoint.Port

        $temp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $temp.Start()
        $closedPort = $temp.LocalEndpoint.Port
        $temp.Stop()
    }

    AfterAll {
        $listener.Stop()
    }

    It 'reports an open port' {
        $result = Invoke-TcpScan -Target '127.0.0.1' -Port "$openPort"
        $result.IPAddress | Should -Be '127.0.0.1'
        $result.Port | Should -Be $openPort
        $result.Status | Should -Be 'Open'
    }

    It 'reports a closed port' {
        $result = Invoke-TcpScan -Target '127.0.0.1' -Port "$closedPort"
        $result.Status | Should -Be 'Closed'
    }

    It 'emits one result object per host and port' {
        $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port "$openPort,$closedPort")
        $results.Count | Should -Be 2
        $results[0].PSObject.Properties.Name | Should -Be @('IPAddress', 'Port', 'Status', 'LatencyMs')
    }

    It 'reports initial progress and clears it when finished' {
        Mock Write-Progress {} -ModuleName TcpScanner

        $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port "$openPort,$closedPort" -ThrottleLimit 1)

        $results.Count | Should -Be 2
        Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
            -not $Completed -and $PercentComplete -eq 0 -and
            $Status -like '*0 of 2*' -and $CurrentOperation -like '*127.0.0.1:*'
        }
        Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -Exactly -ParameterFilter {
            $Completed
        }
    }

    It 'requires -Force above the probe limit' {
        { Invoke-TcpScan -Target '10.0.0.0/16' -Port '1-2' } | Should -Throw '*-Force*'
    }

    It 'requires -Force when the ports alone exceed the probe limit' {
        Mock ConvertTo-IPv4HostList { throw 'Target expansion should not run.' } -ModuleName TcpScanner

        { Invoke-TcpScan -Target '127.0.0.1' -Port '1-65535' } | Should -Throw '*-Force*'

        Should -Invoke ConvertTo-IPv4HostList -ModuleName TcpScanner -Times 0 -Exactly
    }

    It 'accepts --Summarize through the entry script' {
        $results = @(& (Join-Path $PSScriptRoot '..\Invoke-TcpScan.ps1') -Target '127.0.0.1' -Port "$openPort,$closedPort" --Summarize)

        $results.Count | Should -Be 1
        $results[0].IPAddress | Should -Be '127.0.0.1'
        $results[0].OpenPorts | Should -Be "$openPort"
        $results[0].PSObject.Properties.Name | Should -Be @('IPAddress', 'OpenPorts')
    }

    It 'forwards open-only mode through the entry script' {
        $results = @(& (Join-Path $PSScriptRoot '..\Invoke-TcpScan.ps1') -Target '127.0.0.1' -Port "$openPort,$closedPort" -OpenOnly)

        $results.Count | Should -Be 1
        $results[0].IPAddress | Should -Be '127.0.0.1'
        $results[0].Port | Should -Be $openPort
        $results[0].Status | Should -Be 'Open'
        $results[0].PSObject.Properties.Name | Should -Be @('IPAddress', 'Port', 'Status', 'LatencyMs')
    }

    It 'rejects combining open-only streaming with summary mode' {
        { Invoke-TcpScan -Target '127.0.0.1' -Port '1' -OpenOnly -Summarize } | Should -Throw '*cannot be combined*'
    }

    Describe 'standalone script' {
        BeforeAll {
            $standalonePath = Join-Path $TestDrive 'Invoke-TcpScan.ps1'
            Copy-Item (Join-Path $PSScriptRoot '..\Invoke-TcpScan.ps1') $standalonePath
        }

        It 'keeps script and function parameter signatures synchronized' {
            $scriptCommand = Get-Command $standalonePath
            $functionCommand = Get-Command Invoke-TcpScan

            @($scriptCommand.Parameters.Keys | Sort-Object) | Should -Be @($functionCommand.Parameters.Keys | Sort-Object)
            foreach ($parameterName in $scriptCommand.Parameters.Keys) {
                $scriptCommand.Parameters[$parameterName].ParameterType | Should -Be $functionCommand.Parameters[$parameterName].ParameterType
            }
        }

        It 'runs <Mode> mode without any adjacent files' -TestCases @(
            @{ Mode = 'Default' }
            @{ Mode = 'OpenOnly' }
            @{ Mode = 'Summarize' }
        ) {
            $scanParameters = @{
                Target      = '127.0.0.1'
                Port        = "$openPort,$closedPort"
                ErrorAction = 'Stop'
            }
            if ($Mode -ne 'Default') {
                $scanParameters[$Mode] = $true
            }

            $results = @(& $standalonePath @scanParameters)

            if ($Mode -eq 'Default') {
                $results.Count | Should -Be 2
                @($results | Where-Object Status -eq 'Open').Count | Should -Be 1
                @($results | Where-Object Status -eq 'Closed').Count | Should -Be 1
            }
            elseif ($Mode -eq 'OpenOnly') {
                $results.Count | Should -Be 1
                $results[0].Port | Should -Be $openPort
                $results[0].Status | Should -Be 'Open'
            }
            else {
                $results.Count | Should -Be 1
                $results[0].IPAddress | Should -Be '127.0.0.1'
                $results[0].OpenPorts | Should -Be "$openPort"
            }
        }
    }

    Describe 'scheduling' {
        BeforeAll {
            $originalProbeScript = & (Get-Module TcpScanner) { $script:ProbeScript }
            $probeStateKey = "TcpScanner.Tests.$([guid]::NewGuid().ToString('N'))"
            $probeState = [hashtable]::Synchronized(@{
                Started    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[int]'
                Release    = New-Object System.Threading.ManualResetEventSlim -ArgumentList $true
                BlockFirst = $false
                Fail       = $false
                Statuses   = @{}
            })
            [AppDomain]::CurrentDomain.SetData($probeStateKey, $probeState)
            $testProbeScript = [scriptblock]::Create(@"
param([string]`$IPAddress, [int]`$Port, [int]`$TimeoutMs)
`$state = [AppDomain]::CurrentDomain.GetData('$probeStateKey')
`$state.Started.Enqueue(`$Port)
if (`$state.Fail) {
    throw 'Synthetic probe failure.'
}
if (`$state.BlockFirst -and `$Port -eq 1 -and -not `$state.Release.Wait(5000)) {
    throw 'Timed out waiting for the test to release the probe.'
}
`$status = 'Open'
if (`$state.Statuses.ContainsKey(`$Port)) {
    `$status = `$state.Statuses[`$Port]
}
[PSCustomObject]@{ IPAddress = `$IPAddress; Port = `$Port; Status = `$status; LatencyMs = 0 }
"@)
            & (Get-Module TcpScanner) {
                param($probeScript)
                $script:ProbeScript = $probeScript
            } $testProbeScript
        }

        BeforeEach {
            $probeState.Started = New-Object 'System.Collections.Concurrent.ConcurrentQueue[int]'
            $probeState.BlockFirst = $false
            $probeState.Fail = $false
            $probeState.Statuses = @{}
            $probeState.Release.Set()
        }

        AfterAll {
            & (Get-Module TcpScanner) {
                param($probeScript)
                $script:ProbeScript = $probeScript
            } $originalProbeScript
            $probeState.Release.Dispose()
            [AppDomain]::CurrentDomain.SetData($probeStateKey, $null)
        }

        It 'streams results before scheduling the remaining probes' {
            $startedCounts = New-Object 'System.Collections.Generic.List[int]'

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-4' -ThrottleLimit 1 | ForEach-Object {
                $startedCounts.Add($probeState.Started.Count)
                $_
            })

            $results.Port | Should -Be @(1, 2, 3, 4)
            $startedCounts.ToArray() | Should -Be @(1, 2, 3, 4)
        }

        It 'streams open-only results before scheduling the remaining probes' {
            $probeState.Statuses = @{ 2 = 'Closed'; 3 = 'Filtered' }
            $startedCounts = New-Object 'System.Collections.Generic.List[int]'
            Mock Write-Progress {} -ModuleName TcpScanner

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-4' -ThrottleLimit 1 -OpenOnly | ForEach-Object {
                $startedCounts.Add($probeState.Started.Count)
                $_
            })

            $results.Port | Should -Be @(1, 4)
            $results.Status | Should -Be @('Open', 'Open')
            $startedCounts.ToArray() | Should -Be @(1, 4)
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
                -not $Completed -and $PercentComplete -eq 100 -and $Status -like '*2 open*' -and
                $CurrentOperation -eq 'Last open: 127.0.0.1:4'
            }
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 0 -Exactly -ParameterFilter {
                $CurrentOperation -like 'Probing *'
            }
        }

        It 'updates open-only progress while another probe is waiting' {
            $probeState.BlockFirst = $true
            $probeState.Statuses = @{ 1 = 'Closed' }
            $probeState.Release.Reset()
            Mock Write-Progress {
                if (-not $Completed -and $Status -like '*1 open*' -and $CurrentOperation -eq 'Last open: 127.0.0.1:2') {
                    $probeState.Release.Set()
                }
            } -ModuleName TcpScanner

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-2' -ThrottleLimit 2 -OpenOnly)

            $results.Count | Should -Be 1
            $results[0].Port | Should -Be 2
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
                -not $Completed -and $PercentComplete -eq 50 -and $Status -like '*1 open*' -and
                $CurrentOperation -eq 'Last open: 127.0.0.1:2'
            }
        }

        It 'emits no open-only results when no connections succeed' {
            $probeState.Statuses = @{ 1 = 'Closed'; 2 = 'Filtered' }
            Mock Write-Progress {} -ModuleName TcpScanner

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-2' -OpenOnly)

            $results.Count | Should -Be 0
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
                -not $Completed -and $PercentComplete -eq 100 -and $Status -like '*0 open*' -and
                $CurrentOperation -eq 'Waiting for an open TCP connection'
            }
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -Exactly -ParameterFilter {
                $Completed
            }
        }

        It 'summarizes only open ports by IP address with sorted unique ports' {
            $probeState.Statuses = @{ 2 = 'Closed'; 3 = 'Filtered' }
            Mock Write-Progress {} -ModuleName TcpScanner

            $results = @(Invoke-TcpScan -Target '127.0.0.1,127.0.0.2' -Port '10,3,2,1,10' -ThrottleLimit 2 -Summarize)

            $results.Count | Should -Be 2
            $results.IPAddress | Should -Be @('127.0.0.1', '127.0.0.2')
            $results.OpenPorts | Should -Be @('1, 10', '1, 10')
            $results[0].PSObject.Properties.Name | Should -Be @('IPAddress', 'OpenPorts')
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
                -not $Completed -and $PercentComplete -eq 100 -and $Status -like '8 of 8*'
            }
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -Exactly -ParameterFilter {
                $Completed
            }
        }

        It 'emits no summary rows when no TCP connections succeed' {
            $probeState.Statuses = @{ 1 = 'Closed'; 2 = 'Filtered' }

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-2' -Summarize)

            $results.Count | Should -Be 0
        }

        It 'reports intermediate progress and returns fast probes before a waiting probe' {
            $probeState.BlockFirst = $true
            $probeState.Release.Reset()
            Mock Write-Progress {
                if (-not $Completed -and $Status -like '1 of 2*') {
                    $probeState.Release.Set()
                }
            } -ModuleName TcpScanner

            $results = @(Invoke-TcpScan -Target '127.0.0.1' -Port '1-2' -ThrottleLimit 2)

            $results.Port | Should -Be @(2, 1)
            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -ParameterFilter {
                -not $Completed -and $PercentComplete -eq 50 -and
                $Status -like '1 of 2*' -and $CurrentOperation -eq 'Probing 127.0.0.1:1'
            }
        }

        It 'clears progress when a probe fails' {
            $probeState.Fail = $true
            Mock Write-Progress {} -ModuleName TcpScanner

            { Invoke-TcpScan -Target '127.0.0.1' -Port '1-2' -ThrottleLimit 2 } | Should -Throw '*Synthetic probe failure*'

            Should -Invoke Write-Progress -ModuleName TcpScanner -Times 1 -Exactly -ParameterFilter {
                $Completed
            }
        }
    }
}
 