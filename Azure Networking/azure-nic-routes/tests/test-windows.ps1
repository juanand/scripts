#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../windows/azure-nic-routes.ps1') -LibraryOnly
$WarningPreference = 'SilentlyContinue'
$script:passed = 0

function New-TestInventory {
    [pscustomobject]@{
        Interfaces = @(
            [pscustomobject]@{ Index=7; Alias='secondaryA'; Mac='00:11:22:33:44:22'; Address='172.16.0.4'; PrefixLength=25; Gateways=@([pscustomobject]@{ Address='172.16.0.126'; Evidence='fixture-DHCP' }) }
            [pscustomobject]@{ Index=3; Alias='secondaryB'; Mac='00:11:22:33:44:64'; Address='192.168.1.4'; PrefixLength=23; Gateways=@([pscustomobject]@{ Address='192.168.0.254'; Evidence='fixture-DHCP' }) }
            [pscustomobject]@{ Index=9; Alias='primary'; Mac='00:11:22:33:44:b4'; Address='10.0.0.5'; PrefixLength=20; Gateways=@([pscustomobject]@{ Address='10.0.0.254'; Evidence='fixture-default' }) }
        )
        Routes = @(
            [pscustomobject]@{ Destination='0.0.0.0/0'; Index=9; Gateway='10.0.0.254'; Metric=10; Protocol='Dhcp' }
            [pscustomobject]@{ Destination='172.16.0.0/25'; Index=7; Gateway='0.0.0.0'; Metric=256; Protocol='Local' }
            [pscustomobject]@{ Destination='192.168.0.0/23'; Index=3; Gateway='0.0.0.0'; Metric=256; Protocol='Local' }
            [pscustomobject]@{ Destination='10.0.0.0/20'; Index=9; Gateway='0.0.0.0'; Metric=256; Protocol='Local' }
        )
        SavedRoutes = @()
    }
}

function Assert-Case {
    param([string] $Name, [scriptblock] $Body, [string] $ExpectedError = '')
    $caught = $null
    try { $null = & $Body } catch { $caught = $_ }
    if ($ExpectedError) {
        if (-not $caught -or $caught.Exception.Message -notlike "*$ExpectedError*") { throw "${Name}: expected '$ExpectedError', got '$caught'" }
    }
    elseif ($caught) { throw "${Name}: $caught" }
    $script:passed++
    Write-Host "PASS $Name"
}

$mappings = @('172.16.0.0/16=172.16.0.0/16', '192.168.0.0/16=192.168.0.0/16', '10.0.0.0/8=10.0.0.0/8,172.20.0.0/16')
$hostMappings = @('172.16.0.4/32=172.16.0.0/16', '192.168.1.4/32=192.168.0.0/16', '10.0.0.5/32=10.0.0.0/8,172.20.0.0/16')
$inventory = New-TestInventory
Assert-Case 'primary comes from default routes rather than NIC order' { if ((Get-MultiNicPrimary $inventory) -ne 9) { throw 'Wrong primary' } }
Assert-Case 'subnet maps expand destination lists and retain actual prefixes and gateways' {
    $plan = @(New-MultiNicPlan $inventory $mappings)
    if ($plan.Count -ne 4 -or $plan[0].Gateway -ne '172.16.0.126' -or $plan[1].Source -ne '192.168.1.4') { throw 'Wrong map plan' }
}
Assert-Case 'exact /32 mappings retain actual NIC prefixes and gateways' {
    $plan = @(New-MultiNicPlan $inventory $hostMappings)
    $selected = Resolve-MultiNicSelector $inventory '172.16.0.4/32'
    if ($plan.Count -ne 4 -or $plan[0].Gateway -ne '172.16.0.126' -or $selected.PrefixLength -ne 25) { throw 'Host selector changed actual subnet or gateway' }
}
Assert-Case 'unassigned /32 inside a NIC subnet is not matched' {
    if (@(New-MultiNicPlan $inventory @('172.16.0.5/32=172.16.0.0/16')).Count) { throw 'Matched an unassigned local address' }
}
Assert-Case 'overlapping subnet and exact-host mappings fail' { New-MultiNicPlan $inventory @('172.16.0.0/16=172.16.0.0/16', '172.16.0.4/32=172.24.0.0/16') } 'Overlapping NIC'
Assert-Case '/32 gateway override uses the actual NIC subnet' {
    $plan = @(New-MultiNicPlan $inventory $hostMappings @('172.16.0.4/32=172.16.0.125'))
    if ($plan[0].Gateway -ne '172.16.0.125') { throw 'Host gateway override was not used' }
}
Assert-Case '/32 gateway override rejects an off-subnet gateway' { New-MultiNicPlan $inventory $hostMappings @('172.16.0.4/32=172.16.1.1') } 'Gateway'
foreach ($bad in '172.16.0.0/33', '172.16.0.4/16', '0.0.0.0/0', '172.16.0.256/16', '0172.16.0.0/16') {
    $expected = if ($bad -in '172.16.0.4/16', '0.0.0.0/0') { 'canonical' } else { 'IPv4' }
    Assert-Case "reject invalid/canonical CIDR $bad" { Get-IPv4Prefix $bad -Destination } $expected
}
Assert-Case 'missing NIC map warns and other maps remain usable' {
    $warnings = @()
    $plan = @(New-MultiNicPlan $inventory (@('172.24.0.0/16=172.24.0.0/16') + $mappings) -WarningVariable warnings)
    if ($plan.Count -ne 4 -or $warnings.Count -ne 1) { throw 'Unmatched map was not skipped with a warning' }
}
Assert-Case 'all unmatched maps give an empty plan' { if (@(New-MultiNicPlan $inventory @('172.24.0.0/16=172.24.0.0/16')).Count) { throw 'Unexpected routes' } }
Assert-Case 'unmatched map destination is still validated' { New-MultiNicPlan $inventory @('172.24.0.0/16=172.24.0.1/16') } 'canonical'
Assert-Case 'overlapping NIC selectors fail' { New-MultiNicPlan $inventory @('172.16.0.0/16=172.16.0.0/16', '172.16.0.0/24=172.24.0.0/16') } 'Overlapping NIC'
Assert-Case 'overlapping destinations fail' { New-MultiNicPlan $inventory @('172.16.0.0/16=172.24.0.0/16', '192.168.0.0/16=172.24.0.0/16') } 'Overlapping destination'
Assert-Case 'empty destination fails' { New-MultiNicPlan $inventory @('172.16.0.0/16=172.16.0.0/16,') } 'CIDR'
$inventory.Interfaces[0].PrefixLength = 16
Assert-Case 'NIC prefix broader than its selector is not matched' { if (Resolve-MultiNicSelector $inventory '172.16.0.0/24' -AllowMissing) { throw 'Wrong selector match' } }
$inventory = New-TestInventory
$inventory.Interfaces += $inventory.Interfaces[0]
Assert-Case 'multiple matching local addresses fail' { New-MultiNicPlan $inventory $mappings } 'Multiple local'
Assert-Case 'duplicate exact addresses are ambiguous for /32 selectors' { New-MultiNicPlan $inventory $hostMappings } 'Multiple local'
$inventory = New-TestInventory
Assert-Case 'exactly connected destination stays direct' { if (@(New-MultiNicPlan $inventory @('172.16.0.0/16=172.16.0.0/25')).Count) { throw 'Connected route added' } }
Assert-Case 'aggregate containing another local NIC fails' { New-MultiNicPlan $inventory @('172.16.0.0/16=128.0.0.0/1') } 'another local NIC'
foreach ($badGateway in '172.16.1.1', '172.16.0.4', '172.16.0.127') {
    Assert-Case "reject invalid gateway $badGateway" { New-MultiNicPlan $inventory $mappings @("172.16.0.0/16=$badGateway") } 'Gateway'
}
Assert-Case 'duplicate gateway overrides fail' { New-MultiNicPlan $inventory $mappings @('172.16.0.0/16=172.16.0.125', '172.16.0.0/24=172.16.0.126') } 'Duplicate gateway'
$inventory.Interfaces[0].Gateways = @()
Assert-Case 'missing Windows gateway uses the actual Azure subnet plus one' {
    $plan = @(New-MultiNicPlan $inventory $hostMappings)
    if ($plan[0].Gateway -ne '172.16.0.1' -or $plan[0].Evidence -ne 'Azure-subnet-plus-one(172.16.0.4/25)') { throw 'Incorrect calculated gateway evidence' }
}
Assert-Case 'explicit subnet gateway override handles missing evidence' { New-MultiNicPlan $inventory $mappings @('172.16.0.0/16=172.16.0.126') }
foreach ($unsupportedPrefix in 0, 1, 30, 31, 32) {
    $inventory.Interfaces[0].PrefixLength = $unsupportedPrefix
    Assert-Case "unsupported Azure calculation prefix /$unsupportedPrefix requires override" { Get-MultiNicGateway $inventory $inventory.Interfaces[0] @() } 'Cannot calculate'
}
$inventory.Interfaces[0].Address = '172.16.0.5'; $inventory.Interfaces[0].PrefixLength = 30
Assert-Case 'explicit valid gateway can bypass unsupported calculation inputs' { Get-MultiNicGateway $inventory $inventory.Interfaces[0] @('172.16.0.0/16=172.16.0.6') }
$inventory = New-TestInventory
$inventory.Interfaces[1].Gateways = @()
Assert-Case 'Azure /23 gateway uses actual network rather than host final octet' {
    $gateway = Get-MultiNicGateway $inventory $inventory.Interfaces[1] @()
    if ($gateway.Address -ne '192.168.0.1') { throw 'Wrong /23 gateway' }
}
$inventory = New-TestInventory
$inventory.Interfaces[0].Gateways[0].Address = 'invalid'
Assert-Case 'invalid discovered gateway cannot silently trigger Azure calculation' { New-MultiNicPlan $inventory $mappings } 'Invalid IPv4'
$inventory = New-TestInventory
$inventory.Interfaces[0].Address='172.16.255.5'; $inventory.Interfaces[0].PrefixLength=29; $inventory.Interfaces[0].Gateways=@()
$inventory.Interfaces[1].Address='192.168.0.133'; $inventory.Interfaces[1].PrefixLength=28; $inventory.Interfaces[1].Gateways=@()
$inventory.Interfaces[2].Address='10.0.1.5'; $inventory.Interfaces[2].PrefixLength=24; $inventory.Interfaces[2].Gateways[0].Address='10.0.1.1'
$inventory.Routes[0].Gateway='10.0.1.1'
$inventory.Routes[1].Destination='172.16.255.0/29'; $inventory.Routes[2].Destination='192.168.0.128/28'; $inventory.Routes[3].Destination='10.0.1.0/24'
Assert-Case 'secondary /29 and /28 NICs without default gateways plan from actual prefixes' {
    $plan = @(New-MultiNicPlan $inventory @('172.16.0.0/15=172.16.0.0/16', '192.168.0.0/16=192.168.0.0/16', '10.0.0.0/24=10.0.0.0/8') -Persist)
    if ($plan.Count -ne 2 -or $plan[0].Gateway -ne '172.16.255.1' -or $plan[1].Gateway -ne '192.168.0.129' -or (Get-MultiNicPrimary $inventory) -ne 9) { throw 'Wrong gateway or unmatched-map handling for secondary NICs' }
}
$inventory = New-TestInventory
$inventory.Interfaces[0].Gateways += [pscustomobject]@{ Address='172.16.0.125'; Evidence='conflict' }
Assert-Case 'conflicting discovery evidence fails' { New-MultiNicPlan $inventory $mappings } 'gateway evidence'
Assert-Case 'gateway override precedes conflicting evidence' { New-MultiNicPlan $inventory $mappings @('172.16.0.0/16=172.16.0.126') }
$inventory = New-TestInventory
$inventory.Routes += [pscustomobject]@{ Destination='0.0.0.0/0'; Index=7; Gateway='172.16.0.126'; Metric=500; Protocol='Dhcp' }
Assert-Case 'multiple default-route NICs fail despite different metrics' { Get-MultiNicPrimary $inventory } 'ambiguous'
$inventory = New-TestInventory
$inventory.Routes += [pscustomobject]@{ Destination='172.16.0.128/25'; Index=9; Gateway='10.0.0.254'; Metric=50; Protocol='NetMgmt' }
Assert-Case 'more-specific conflicting route fails' { New-MultiNicPlan $inventory $mappings } 'More-specific'
$inventory = New-TestInventory
$inventory.Routes += [pscustomobject]@{ Destination='172.16.0.0/15'; Index=9; Gateway='10.0.0.254'; Metric=50; Protocol='NetMgmt' }
Assert-Case 'broader existing route is not a more-specific conflict' { New-MultiNicPlan $inventory $mappings }
$inventory = New-TestInventory
$inventory.SavedRoutes += [pscustomobject]@{ Destination='172.16.0.0/16'; Index=7; Gateway='172.16.0.125'; Metric=42762; Protocol='NetMgmt' }
Assert-Case 'saved route collision is rejected before mutation' { New-MultiNicPlan $inventory $mappings } 'collision'
foreach ($badMetric in 0, -1, 65536) {
    Assert-Case "reject out-of-range Windows metric $badMetric" { New-MultiNicPlan (New-TestInventory) $mappings -Metric $badMetric } 'Metric'
}
Assert-Case 'maximum Windows metric is supported' { if (@(New-MultiNicPlan (New-TestInventory) $mappings -Metric 65535)[0].Metric -ne 65535) { throw 'Wrong metric' } }

$script:fixture = New-TestInventory
$script:active = @($script:fixture.Routes)
$script:saved = @()
$script:mutations = 0
$script:events = @()
$script:addFailure = ''
$script:removeFailure = ''
$script:denyAdministrator = $false
$script:dependencyFailure = $false
$script:routeQueryFailure = $null

function Assert-MultiNicDependencies {
    param([switch] $Mutation, [switch] $Cleanup)
    if ($script:dependencyFailure) { throw 'Mock missing OS command' }
}
function Assert-MultiNicAdministrator {
    if ($script:denyAdministrator) { throw 'Mock elevation required' }
}
function Get-NetAdapter {
    [CmdletBinding()] param([switch] $IncludeHidden)
    foreach ($interface in $script:fixture.Interfaces) {
        [pscustomobject]@{ InterfaceIndex=$interface.Index; Name=$interface.Alias; MacAddress=$interface.Mac; InterfaceType=6; Status='Up' }
    }
}
function Get-NetIPAddress {
    [CmdletBinding()] param($AddressFamily)
    if ($AddressFamily -ne 'IPv4') { throw 'Unexpected address family' }
    foreach ($interface in $script:fixture.Interfaces) {
        [pscustomobject]@{ InterfaceIndex=$interface.Index; IPAddress=$interface.Address; PrefixLength=$interface.PrefixLength; AddressState='Preferred'; SkipAsSource=$false }
    }
}
function Get-CimInstance {
    [CmdletBinding()] param($ClassName, $Filter)
    if ($ClassName -ne 'Win32_NetworkAdapterConfiguration') { throw 'Unexpected CIM query' }
    foreach ($interface in $script:fixture.Interfaces) {
        [pscustomobject]@{ InterfaceIndex=$interface.Index; DefaultIPGateway=@($interface.Gateways | ForEach-Object { $_.Address }) }
    }
}
function Get-NetRoute {
    [CmdletBinding()] param($AddressFamily, $PolicyStore)
    if ($AddressFamily -ne 'IPv4' -or $PolicyStore -notin 'ActiveStore', 'PersistentStore') { throw 'Unexpected route read' }
    if ($script:routeQueryFailure) { $PSCmdlet.WriteError($script:routeQueryFailure); return }
    $rows = @(if ($PolicyStore -eq 'ActiveStore') { $script:active } else { $script:saved })
    if (-not $rows.Count) {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('No MSFT_NetRoute objects found with AddressFamily IPv4.'), 'CmdletizationQuery_NotFound_AddressFamily', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $AddressFamily)
        $PSCmdlet.WriteError($errorRecord)
        return
    }
    foreach ($row in $rows) {
        [pscustomobject]@{ DestinationPrefix=$row.Destination; InterfaceIndex=$row.Index; NextHop=$row.Gateway; RouteMetric=$row.Metric; Protocol=$row.Protocol }
    }
}
function New-NetRoute {
    [CmdletBinding()] param($DestinationPrefix, $InterfaceIndex, $NextHop, $RouteMetric, $Protocol, $AddressFamily, $PolicyStore)
    if ($DestinationPrefix -eq $script:addFailure) { throw 'Mock addition failure' }
    if ($AddressFamily -ne 'IPv4' -or $Protocol -ne 'NetMgmt' -or ($PolicyStore -and $PolicyStore -ne 'ActiveStore')) { throw 'Unexpected route addition' }
    $row = [pscustomobject]@{ Destination=$DestinationPrefix; Index=[int]$InterfaceIndex; Gateway=$NextHop; Metric=[int]$RouteMetric; Protocol=$Protocol }
    $script:active += $row
    if (-not $PSBoundParameters.ContainsKey('PolicyStore')) { $script:saved += $row }
    $script:mutations++; $script:events += "add:$PolicyStore"
}
function Remove-NetRoute {
    [CmdletBinding()] param($DestinationPrefix, $InterfaceIndex, $NextHop, $RouteMetric, $Protocol, $AddressFamily, $PolicyStore, [switch] $Confirm)
    if ($DestinationPrefix -eq $script:removeFailure) { throw 'Mock removal failure' }
    if ($AddressFamily -ne 'IPv4' -or $Protocol -ne 'NetMgmt' -or $PolicyStore -notin 'ActiveStore', 'PersistentStore') { throw 'Unexpected route removal' }
    $rows = if ($PolicyStore -eq 'ActiveStore') { $script:active } else { $script:saved }
    $remaining = @($rows | Where-Object { -not ($_.Destination -eq $DestinationPrefix -and $_.Index -eq $InterfaceIndex -and $_.Gateway -eq $NextHop -and $_.Metric -eq $RouteMetric -and $_.Protocol -eq $Protocol) })
    if ($PolicyStore -eq 'ActiveStore') { $script:active = $remaining } else { $script:saved = $remaining }
    $script:mutations++; $script:events += "remove:$PolicyStore"
}

Assert-Case 'empty persistent store native query error becomes an empty result' { if (@(Get-MultiNicRoutes PersistentStore).Count) { throw 'Unexpected saved routes' } }
Assert-Case 'empty active store native query error becomes an empty result' {
    $savedActive = $script:active
    try { $script:active=@(); if (@(Get-MultiNicRoutes ActiveStore).Count) { throw 'Unexpected active routes' } }
    finally { $script:active=$savedActive }
}
foreach ($failure in @(
    @{ Id='AccessDenied'; Category=[System.Management.Automation.ErrorCategory]::PermissionDenied; Message='Mock access denied' }
    @{ Id='CimTransportFailure'; Category=[System.Management.Automation.ErrorCategory]::ResourceUnavailable; Message='Mock CIM unavailable' }
    @{ Id='OtherResourceMissing'; Category=[System.Management.Automation.ErrorCategory]::ObjectNotFound; Message='Mock unrelated missing resource' }
)) {
    Assert-Case "route queries preserve real failure $($failure.Id)" {
        $script:routeQueryFailure=[System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($failure.Message), $failure.Id, $failure.Category, $null)
        try { Get-MultiNicRoutes PersistentStore }
        finally { $script:routeQueryFailure=$null }
    } $failure.Message
}
Assert-Case 'mocked live discovery correlates addresses MACs gateways and an empty persistent store' { if ((Get-MultiNicInventory).Interfaces.Count -ne 3) { throw 'Wrong discovery' } }
Assert-Case 'native discovery and persistent apply calculate absent secondary gateways idempotently' {
    $baselineFixture=$script:fixture; $baselineActive=$script:active; $baselineSaved=$script:saved
    $baselineMutations=$script:mutations; $baselineEvents=$script:events
    try {
        $script:fixture=New-TestInventory
        $script:fixture.Interfaces[0].Gateways=@(); $script:fixture.Interfaces[1].Gateways=@()
        $script:active=@($script:fixture.Routes); $script:saved=@()
        Invoke-MultiNicRouting -Mappings $hostMappings -Apply -Persist
        if ($script:saved.Count -ne 4 -or @($script:saved | Where-Object { $_.Index -eq 7 -and $_.Gateway -eq '172.16.0.1' }).Count -ne 1 -or @($script:saved | Where-Object { $_.Index -eq 3 -and $_.Gateway -eq '192.168.0.1' }).Count -ne 1) { throw 'Full discovery/apply did not use actual-subnet gateways' }
        $afterFirstApply=$script:mutations
        Invoke-MultiNicRouting -Mappings $hostMappings -Apply -Persist
        if ($script:mutations -ne $afterFirstApply) { throw 'Calculated gateway reapply changed routes' }
    }
    finally {
        $script:fixture=$baselineFixture; $script:active=$baselineActive; $script:saved=$baselineSaved
        $script:mutations=$baselineMutations; $script:events=$baselineEvents
    }
}
Assert-Case 'default full preview does not mutate any route' { Invoke-MultiNicRouting -Mappings $mappings; if ($script:mutations) { throw 'Preview mutation' } }
Assert-Case 'all unmatched full apply is explicitly a no-op' {
    $output = Invoke-MultiNicRouting -Mappings @('172.24.0.0/16=172.24.0.0/16') -Apply 6>&1 | Out-String
    if ($script:mutations -or $output -notmatch 'No matching route changes. No changes made.') { throw 'Empty plan did not return as a no-op' }
}
Assert-Case 'missing dependency blocks apply before mutation' { $script:dependencyFailure=$true; try { Invoke-MultiNicRouting -Mappings $mappings -Apply } finally { $script:dependencyFailure=$false } } 'missing OS command'
Assert-Case 'missing elevation blocks apply before mutation' { $script:denyAdministrator=$true; try { Invoke-MultiNicRouting -Mappings $mappings -Apply } finally { $script:denyAdministrator=$false } } 'elevation'
Assert-Case 'a late invalid map prevents every addition' { Invoke-MultiNicRouting -Mappings ($mappings + '172.24.0.0/16=bad') -Apply } 'CIDR'
if ($script:mutations) { throw 'Failed preflight mutated a route' }
Assert-Case 'runtime apply changes only ActiveStore and leaves defaults intact' {
    Invoke-MultiNicRouting -Mappings $mappings -Apply
    if ($script:mutations -ne 4 -or $script:saved.Count -or @($script:active | Where-Object Destination -eq '0.0.0.0/0').Count -ne 1) { throw 'Wrong runtime apply' }
}
Assert-Case 'second runtime apply is idempotent' { Invoke-MultiNicRouting -Mappings $mappings -Apply; if ($script:mutations -ne 4) { throw 'Repeated apply mutated' } }
Assert-Case 'existing runtime routes require reviewed rollback before enabling persistence' { Invoke-MultiNicRouting -Mappings $mappings -Apply -Persist } 'active-only'
Assert-Case 'cleanup preview does not mutate stores' { Invoke-MultiNicRouting -Cleanup Rollback; if ($script:mutations -ne 4) { throw 'Cleanup preview mutation' } }
Assert-Case 'rollback removes runtime routes by metric without private files' { Invoke-MultiNicRouting -Cleanup Rollback -Apply; if ($script:active.Count -ne 4 -or $script:saved.Count) { throw 'Rollback changed baseline' } }
Assert-Case 'persistent apply uses native dual-store creation' { Invoke-MultiNicRouting -Mappings $mappings -Metric 50000 -Apply -Persist; if ($script:saved.Count -ne 4) { throw 'Saved routes missing' } }
$before = $script:mutations
Assert-Case 'persistent second apply is idempotent' { Invoke-MultiNicRouting -Mappings $mappings -Metric 50000 -Apply -Persist; if ($script:mutations -ne $before) { throw 'Persistent apply duplicated' } }
$script:active = @($script:fixture.Routes) + @($script:saved)
Assert-Case 'persistent apply recognizes routes after simulated reboot' { Invoke-MultiNicRouting -Mappings $mappings -Metric 50000 -Apply -Persist; if ($script:mutations -ne $before) { throw 'Reboot reapply duplicated' } }
Assert-Case 'default rollback preserves a different metric' { Invoke-MultiNicRouting -Cleanup Rollback -Apply; if ($script:saved.Count -ne 4) { throw 'Wrong rollback metric' } }
Assert-Case 'custom metric rollback removes saved routes before active routes' {
    $script:events=@(); Invoke-MultiNicRouting -Cleanup Rollback -Metric 50000 -Apply
    if ($script:saved.Count -or $script:active.Count -ne 4 -or $script:events[0] -ne 'remove:PersistentStore') { throw 'Incorrect cleanup stores/order' }
}
$manual = [pscustomobject]@{ Destination='172.30.0.0/16'; Index=7; Gateway='172.16.0.126'; Metric=100; Protocol='NetMgmt' }
$dhcp = [pscustomobject]@{ Destination='172.31.0.0/16'; Index=7; Gateway='172.16.0.126'; Metric=42762; Protocol='Dhcp' }
$excluded = [pscustomobject]@{ Destination='172.29.0.0/16'; Index=99; Gateway='10.0.0.254'; Metric=100; Protocol='NetMgmt' }
$script:active += $manual, $dhcp, $excluded
$script:saved += $manual, $script:fixture.Routes[0]
Assert-Case 'reset removes manual routes across metrics but preserves defaults local DHCP and other NICs' {
    Invoke-MultiNicRouting -Cleanup Reset -Apply
    if ($script:active.Count -ne 6 -or $script:saved.Count -ne 1 -or @($script:active | Where-Object Destination -eq $manual.Destination).Count) { throw 'Reset changed protected routes' }
}
$before = $script:mutations
Assert-Case 'repeated cleanup with no custom routes is a no-op' { Invoke-MultiNicRouting -Cleanup Reset -Apply; if ($script:mutations -ne $before) { throw 'No-op cleanup mutated' } }
Assert-Case 'cleanup cannot take map or persistence parameters' { Invoke-MultiNicRouting -Cleanup Reset -Mappings $mappings -Apply } 'separate'
Assert-Case 'fixture input cannot authorize mutation' { Invoke-MultiNicRouting -Mappings $mappings -FixturePath 'unused.json' -Apply } 'Offline inventory'
$script:addFailure='192.168.0.0/16'
Assert-Case 'partial addition failure is reported without hiding earlier changes' { Invoke-MultiNicRouting -Mappings $mappings -Apply -Persist } 'addition failure'
$script:addFailure=''
Assert-Case 'metric rollback recovers a partial persistent apply' { Invoke-MultiNicRouting -Cleanup Rollback -Apply; if (@($script:active | Where-Object Metric -eq 42762 | Where-Object Protocol -eq 'NetMgmt').Count) { throw 'Partial route remains' } }
Assert-Case 'fresh persistent apply before cleanup failure test' { Invoke-MultiNicRouting -Mappings $mappings -Apply -Persist }
$script:removeFailure='192.168.0.0/16'
Assert-Case 'saved cleanup failure is reported before active removals' { Invoke-MultiNicRouting -Cleanup Rollback -Apply } 'removal failure'
$script:removeFailure=''
if (@($script:active | Where-Object Metric -eq 42762 | Where-Object Protocol -eq 'NetMgmt').Count -ne 4) { throw 'Active routes removed before saved cleanup completed' }
Assert-Case 'cleanup retry handles already removed saved entries' {
    Invoke-MultiNicRouting -Cleanup Rollback -Apply
    if (@($script:active | Where-Object Metric -eq 42762 | Where-Object Protocol -eq 'NetMgmt').Count -or @($script:saved | Where-Object Metric -eq 42762 | Where-Object Protocol -eq 'NetMgmt').Count) { throw 'Cleanup retry left a selected route' }
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('nic-routes-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
try {
    $fixturePath=Join-Path $temporaryDirectory 'inventory.json'
    New-TestInventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixturePath -Encoding ASCII
    Assert-Case 'offline preview uses explicit fixture without mutation' { Invoke-MultiNicRouting -Mappings $mappings -FixturePath $fixturePath }
    $copyPath=Join-Path $temporaryDirectory 'renamed-tool.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../windows/azure-nic-routes.ps1') -Destination $copyPath
    Assert-Case 'plain native help uses actual filename without executing the script' {
        $basicHelp = Get-Help -Name $copyPath
        $formatted = $basicHelp | Out-String
        foreach ($heading in 'NAME', 'SYNOPSIS', 'SYNTAX', 'DESCRIPTION') { if ($formatted -notmatch "(?m)^$heading\s*$") { throw "Missing standard help section $heading" } }
        if ($basicHelp.Name -notmatch 'renamed-tool.ps1' -or $basicHelp.Synopsis -notmatch 'IPv4 destination routes') { throw 'Missing renamed script help' }
    }
    Assert-Case 'native Get-Help includes synopsis and parameter descriptions' {
        $nativeHelp = Get-Help -Name $copyPath -Full
        if ($nativeHelp.Synopsis -notmatch 'IPv4 destination routes' -or ($nativeHelp.Parameters.Parameter | Where-Object Name -eq 'Map').Description.Text -notmatch 'NIC_CIDR') { throw 'Missing comment-based help' }
    }
    Assert-Case 'native Get-Help examples cover preview persistence rollback and reset' {
        $examples = Get-Help -Name $copyPath -Examples
        $text = $examples | Out-String
        if (@($examples.Examples.Example).Count -lt 4 -or $text -notmatch 'Persist' -or $text -notmatch 'Rollback' -or $text -notmatch 'Reset') { throw 'Missing native help examples' }
    }
    Assert-Case 'custom Help switch is not exposed' { if ((Get-Command $copyPath).Parameters.ContainsKey('Help')) { throw 'Nonstandard Help switch remains' } }
    Assert-Case 'custom Help switch is rejected by native parameter binding' { & $copyPath -Help } 'cannot be found'
    Assert-Case 'public PowerShell array syntax previews all maps without mutation' { & $copyPath -Map $mappings -InventoryPath $fixturePath }
    Assert-Case 'Bash double-hyphen maps are rejected before positional metric conversion' {
        try { & $copyPath --map '172.16.0.0/16=172.16.0.0/16' --map '192.168.0.0/16=192.168.0.0/16' --map '10.0.0.0/8=10.0.0.0/8' -Apply; throw 'Bash syntax unexpectedly accepted' }
        catch {
            if ($_.FullyQualifiedErrorId -notlike '*PositionalParameterNotFound*') { throw "Wrong binding failure: $($_.FullyQualifiedErrorId)" }
        }
    }
    Assert-Case 'repeated Map parameters use a native duplicate-parameter error' { & $copyPath -Map '172.16.0.0/16=172.16.0.0/16' -Map '192.168.0.0/16=192.168.0.0/16' } 'more than once'
    Assert-Case 'public entry rejects simultaneous cleanup modes' { & $copyPath -Rollback -Reset } 'Choose only one'
    Assert-Case 'reset rejects a misleading metric filter' { & $copyPath -Reset -Metric 100 } 'covers all'
    Assert-Case 'Windows script is ASCII for Windows PowerShell parsing' { if ([System.IO.File]::ReadAllText($copyPath) -match '[^\x00-\x7F]') { throw 'Non-ASCII script content' } }
    Assert-Case 'Windows script has no private-state or non-route mutation commands' {
        $text=[System.IO.File]::ReadAllText($copyPath)
        if ($text -match 'ProgramData|Journal|Set-Net|Restart-Net|Remove-NetIPAddress|Set-Content|New-Item') { throw 'Unexpected mutation surface' }
    }
}
finally { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
Write-Host "$script:passed isolated PowerShell checks passed on $($PSVersionTable.PSVersion); no OS networking cmdlets executed."