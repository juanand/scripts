# TCP Scanner (PowerShell)

A PowerShell tool that runs quick TCP handshake checks (connect only, no payload) against targets on a corporate Windows network.

## Scope

* Ports: single (`443`), list (`80,443`), range (`80-90`), or a mix (`22,80-90,443`).
* Targets: single IPv4 (`10.0.0.1`) or CIDR (`10.0.0.1/32`, `10.0.0.0/28`).
* Result per IP/port: `Open` (handshake completed), `Closed` (refused/reset), or `Filtered` (timeout).
* Out of scope: UDP, SYN/half-open scans, banner grabbing, service fingerprinting, and IPv6 unless requested.

## Environment constraints

* Target Windows PowerShell 5.1 and PowerShell 7+. Do not use 7-only features such as `ForEach-Object -Parallel`, `??`, `?:`, or `&&`.
* A corporate proxy blocks the PowerShell Gallery and NuGet. Do not assume `Install-Module` works. Use built-in .NET types only.
* Pester 5.7.1 is installed for PowerShell 7. Windows PowerShell 5.1 has only Pester 3.4, so run tests from `pwsh` and use Pester 5 syntax (`Should -Be`).
* No admin rights. The scanner must not require elevation, raw sockets, or drivers.

## Layout

* [Invoke-TcpScan.ps1](Invoke-TcpScan.ps1) is self-contained and holds `ConvertTo-PortList`, `ConvertTo-IPv4HostList`, and `Invoke-TcpScan`. No module or adjacent files are needed to run it.
* Keep its script and function parameter blocks in sync. Dot-sourcing loads the functions without starting a scan; supply `-Target` and `-Port` to satisfy script parameter binding.
* [tests/TcpScanner.Tests.ps1](tests/TcpScanner.Tests.ps1) loads the script into an in-memory module for isolated mocks and also tests standalone copies of the script.

## Implementation guidance

* Windows retries a SYN after receiving an RST, so a closed port takes about 2 s to report and would show as `Filtered`. The probe sets `SIO_TCP_INITIAL_RTO` with no SYN retransmissions to avoid this. Keep that setting.
* Use `System.Net.Sockets.TcpClient` with `ConnectAsync(...)` and `.Wait(timeoutMs)` for each probe. Do not use `Test-NetConnection`; it is slow and has no timeout control.
* Always dispose the `TcpClient` (`try/finally`), including on timeout.
* Use a runspace pool for concurrency, with a configurable throttle (default about 100) and timeout (default about 500 ms).
* Keep parsing separate from probing so you can unit test it without a network:
  * The port parser expands lists and ranges. Validate 1–65535, require start <= end, and de-duplicate.
  * The CIDR parser expands to host addresses with uint32 math, handling byte order with `[BitConverter]`. Validate prefix 0–32. `/32` gives one host and `/31` gives two. For `/30` and larger networks, exclude the network and broadcast addresses unless a switch says otherwise.
  * Add a guard against huge expansions, such as a `/8` across all ports, by requiring `-Force` above a threshold.
* Emit `[PSCustomObject]` results with `IPAddress`, `Port`, `Status`, and `LatencyMs`. Do not use `Write-Host` for results, so callers can pipe to `Export-Csv`, `Where-Object`, and other cmdlets.
* Use approved verbs (`Get-Verb`), `[CmdletBinding()]`, and parameter validation attributes.

## Build and test

* Put Pester tests in `tests/*.Tests.ps1` and run them with `Invoke-Pester -Path ./tests`.
* Unit-test the port and CIDR parsers thoroughly. For live probe tests, use `127.0.0.1` with a temporary `System.Net.Sockets.TcpListener` and never external hosts.

## Safety

* Only scan networks the user is authorized to test. Do not add evasion features such as randomized timing to dodge IDS, source spoofing, or decoys.
 