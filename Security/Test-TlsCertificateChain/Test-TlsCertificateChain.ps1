#Requires -Version 7.4

<#
.SYNOPSIS
    Checks whether HTTPS servers send every intermediate CA certificate needed to reach a trusted root.

.DESCRIPTION
    Connects to each host, captures the certificates the server sends during the TLS handshake, and
    validates them the way a client that trusts only the root CA would (for example OpenSSL or curl on
    Linux). Intermediates installed on this machine and AIA downloads never count toward compliance, so
    a server that omits an intermediate is reported even when browsers or Windows tools accept it.

    The script does not depend on a specific PKI. The roots in -RootCaBundle define trust, and the
    intermediates each server must send are derived by chain building. Multiple roots, multiple issuing
    CAs, and multi-level chains are supported.

    Revocation is not checked. No application data is sent to the server.

.PARAMETER HostName
    Host names to check. Accepts pipeline input. Each entry can be a host name, an IP address,
    host:port, [IPv6]:port, or an https:// URL. Blank lines and lines starting with # are ignored.

.PARAMETER RootCaBundle
    Path to a PEM file containing the trusted root CA certificates. Defaults to the value of the
    TLSCHECKER_ROOT_BUNDLE environment variable; when both are set, this parameter takes precedence.
    Certificates in the file that are not self-signed are ignored with a warning, because trusting an
    intermediate would hide servers that don't send it.

.PARAMETER Port
    TCP port used when an entry does not specify one. Defaults to 443.

.PARAMETER TimeoutSeconds
    Timeout for the TCP connection and the TLS handshake. Defaults to 10 seconds.

.EXAMPLE
    .\Test-TlsCertificateChain.ps1 -HostName app1.example.local, app2.example.local -RootCaBundle .\roots.pem

.EXAMPLE
    $env:TLSCHECKER_ROOT_BUNDLE = 'C:\pki\roots.pem'
    Get-Content .\hosts.txt | .\Test-TlsCertificateChain.ps1 | Format-List *

    Uses the root CA bundle from the environment variable instead of -RootCaBundle.

.OUTPUTS
    One object per host. Status is one of Compliant, MissingIntermediate, UntrustedRoot, InvalidChain,
    or ConnectionFailed. The script exits with code 1 when any host is not Compliant.
    SentCertificates lists the leaf first, followed by the other certificates in the order .NET reports
    them, which may differ from the handshake order.
#>

using namespace System.Security.Cryptography.X509Certificates

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('ComputerName')]
    [AllowEmptyString()]
    [string[]]$HostName,

    [string]$RootCaBundle = $env:TLSCHECKER_ROOT_BUNDLE,

    [ValidateRange(1, 65535)]
    [int]$Port = 443,

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 10
)

begin {
    Set-StrictMode -Version Latest

    function Import-RootCaBundle {
        param([Parameter(Mandatory)][string]$Path)

        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        $all = [X509Certificate2Collection]::new()
        try {
            $all.ImportFromPemFile($resolved)
        }
        catch {
            throw "Cannot read PEM certificates from '$resolved': $($_.Exception.GetBaseException().Message)"
        }

        $roots = [X509Certificate2Collection]::new()
        foreach ($certificate in $all) {
            if ($certificate.Subject -eq $certificate.Issuer) {
                [void]$roots.Add($certificate)
            }
            else {
                Write-Warning "Ignoring '$($certificate.Subject)' in '$resolved': it is not a self-signed root CA."
            }
        }
        if ($roots.Count -eq 0) {
            throw "No self-signed root CA certificates found in '$resolved'."
        }
        , $roots
    }

    function Split-HostEntry {
        param([Parameter(Mandatory)][string]$Entry, [Parameter(Mandatory)][int]$DefaultPort)

        $text = $Entry.Trim()
        $name = $text
        $entryPort = $DefaultPort

        if ($text -match '^[a-z][a-z0-9+.-]*://') {
            $uri = [uri]$text
            $name = $uri.IdnHost.Trim('[', ']')
            $entryPort = $uri.Port
        }
        elseif ($text -match '^\[(?<host>[^\]]+)\](?::(?<port>\d+))?$') {
            $name = $Matches.host
            if ($Matches.ContainsKey('port')) { $entryPort = [int]$Matches.port }
        }
        elseif ($text -match '^(?<host>[^:]+):(?<port>\d+)$') {
            $name = $Matches.host
            $entryPort = [int]$Matches.port
        }

        if ($entryPort -lt 1 -or $entryPort -gt 65535) {
            throw "Invalid port in '$Entry'."
        }
        [pscustomobject]@{ HostName = $name; Port = $entryPort }
    }

    function Get-ExtensionByOid {
        param([X509Certificate2]$Certificate, [string]$Oid)
        $Certificate.Extensions | Where-Object { $_.Oid.Value -eq $Oid } | Select-Object -First 1
    }

    function Get-SubjectKeyId {
        param([X509Certificate2]$Certificate)
        $extension = Get-ExtensionByOid $Certificate '2.5.29.14'
        if ($extension) {
            [X509SubjectKeyIdentifierExtension]::new([System.Security.Cryptography.AsnEncodedData]$extension, $extension.Critical).SubjectKeyIdentifier
        }
    }

    function Get-AuthorityKeyId {
        param([X509Certificate2]$Certificate)
        $extension = Get-ExtensionByOid $Certificate '2.5.29.35'
        if ($extension) {
            $keyId = [X509AuthorityKeyIdentifierExtension]::new([byte[]]$extension.RawData, $extension.Critical).KeyIdentifier
            if ($null -ne $keyId) { [Convert]::ToHexString($keyId.ToArray()) }
        }
    }

    function Get-CaIssuersUri {
        param([X509Certificate2]$Certificate)
        $extension = Get-ExtensionByOid $Certificate '1.3.6.1.5.5.7.1.1'
        if ($extension) {
            [X509AuthorityInformationAccessExtension]::new([byte[]]$extension.RawData, $extension.Critical).EnumerateCAIssuersUris()
        }
    }

    function Get-SimpleName {
        param([X509Certificate2]$Certificate)
        $Certificate.GetNameInfo([X509NameType]::SimpleName, $false)
    }

    # Certificates match when they have the same subject and public key. This treats a re-issued copy of
    # the same CA as equivalent, while a renewed CA with a new key is treated as a different certificate.
    function Test-CertificateIn {
        param([X509Certificate2]$Certificate, [X509Certificate2[]]$Collection)
        foreach ($candidate in $Collection) {
            if ($candidate.Subject -eq $Certificate.Subject -and
                $candidate.GetPublicKeyString() -eq $Certificate.GetPublicKeyString()) {
                return $true
            }
        }
        $false
    }

    function New-AnalysisResult {
        param(
            [Parameter(Mandatory)][string]$Status,
            [Parameter(Mandatory)][string]$Detail,
            [int]$SentCount = 0,
            [string[]]$SentCertificates = @(),
            [string[]]$ChainPath = @(),
            [string]$MissingIssuer,
            [string]$MissingIssuerKeyId,
            [string[]]$MissingIssuerAia = @(),
            [bool]$MissingIssuerAvailableLocally = $false,
            [bool]$RootSent = $false,
            [string[]]$UnusedCertificates = @(),
            [string[]]$ChainStatus = @(),
            [string]$LeafSubject,
            [string]$LeafIssuer,
            [Nullable[datetime]]$LeafNotAfter
        )
        [pscustomobject][ordered]@{
            Status                        = $Status
            IsCompliant                   = $Status -eq 'Compliant'
            Detail                        = $Detail
            SentCount                     = $SentCount
            SentCertificates              = $SentCertificates
            ChainPath                     = $ChainPath
            MissingIssuer                 = $MissingIssuer
            MissingIssuerKeyId            = $MissingIssuerKeyId
            MissingIssuerAia              = $MissingIssuerAia
            MissingIssuerAvailableLocally = $MissingIssuerAvailableLocally
            RootSent                      = $RootSent
            UnusedCertificates            = $UnusedCertificates
            ChainStatus                   = $ChainStatus
            LeafSubject                   = $LeafSubject
            LeafIssuer                    = $LeafIssuer
            LeafNotAfter                  = $LeafNotAfter
        }
    }

    function Test-CertificateChainCompliance {
        param(
            [Parameter(Mandatory)][X509Certificate2]$Leaf,
            [AllowEmptyCollection()][X509Certificate2[]]$ServerCertificates = @(),
            [Parameter(Mandatory)][X509Certificate2Collection]$TrustedRoots,
            [datetime]$VerificationTime = [datetime]::Now
        )

        $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Leaf.Thumbprint))
        $sent = [System.Collections.Generic.List[X509Certificate2]]::new()
        foreach ($certificate in $ServerCertificates) {
            if ($seen.Add($certificate.Thumbprint)) { $sent.Add($certificate) }
        }
        $sentArray = [X509Certificate2[]]$sent.ToArray()
        $rootArray = [X509Certificate2[]]@($TrustedRoots)

        $chain = [X509Chain]::new()
        try {
            $policy = $chain.ChainPolicy
            $policy.TrustMode = [X509ChainTrustMode]::CustomRootTrust
            $policy.CustomTrustStore.AddRange($TrustedRoots)
            $policy.ExtraStore.AddRange($sentArray)
            $policy.DisableCertificateDownloads = $true
            $policy.RevocationMode = [X509RevocationMode]::NoCheck
            $policy.VerificationTime = $VerificationTime
            [void]$chain.Build($Leaf)

            $path = @($chain.ChainElements | ForEach-Object { [X509Certificate2]::new($_.Certificate.RawData) })
            $flags = [X509ChainStatusFlags]::NoError
            foreach ($chainStatus in $chain.ChainStatus) { $flags = $flags -bor $chainStatus.Status }
        }
        finally {
            $chain.Dispose()
        }

        # On Windows, chain building also uses intermediates from the local certificate stores even in
        # CustomRootTrust mode. Every intermediate in the path must therefore have been sent by the server.
        $missing = $null
        for ($i = 1; $i -lt $path.Count; $i++) {
            if (Test-CertificateIn $path[$i] $rootArray) { break }
            if (-not (Test-CertificateIn $path[$i] $sentArray)) {
                $keyId = Get-SubjectKeyId $path[$i]
                if (-not $keyId) { $keyId = Get-AuthorityKeyId $path[$i - 1] }
                $missing = @{
                    Subject          = $path[$i].Subject
                    KeyId            = $keyId
                    Aia              = @(Get-CaIssuersUri $path[$i - 1])
                    AvailableLocally = $true
                }
                break
            }
        }

        $anchor = $path[-1]
        $anchorTrusted = Test-CertificateIn $anchor $rootArray
        if (-not $missing -and $flags.HasFlag([X509ChainStatusFlags]::PartialChain)) {
            $missing = @{
                Subject          = $anchor.Issuer
                KeyId            = Get-AuthorityKeyId $anchor
                Aia              = @(Get-CaIssuersUri $anchor)
                AvailableLocally = $false
            }
        }

        $unused = @($sentArray | Where-Object { -not (Test-CertificateIn $_ $path) } | ForEach-Object { $_.Subject })
        $rootSent = [bool]@($sentArray | Where-Object { $_.Subject -eq $_.Issuer }).Count
        $statusNames = @(if ($flags -ne [X509ChainStatusFlags]::NoError) { $flags.ToString() -split ',\s*' })

        if ($missing) {
            $status = 'MissingIntermediate'
            $detail = "Server does not send intermediate CA '$($missing.Subject)'."
            if ($missing.AvailableLocally) {
                $detail += ' This machine has a local copy, so local browsers and Windows tools may accept the server.'
            }
            if ($unused.Count) {
                $detail += " Server sends unrelated certificate(s): $($unused -join '; ')."
            }
        }
        elseif (-not $anchorTrusted) {
            $status = 'UntrustedRoot'
            $detail = "Chain ends at '$($anchor.Subject)', which is not in the root CA bundle."
        }
        elseif ($statusNames.Count) {
            $status = 'InvalidChain'
            $detail = "Chain validation failed: $($statusNames -join ', ')."
        }
        else {
            $status = 'Compliant'
            $intermediateCount = [Math]::Max(0, $path.Count - 2)
            $detail = "Server sends every required intermediate ($intermediateCount); chain reaches trusted root '$(Get-SimpleName $anchor)'."
        }

        $result = @{
            Status             = $status
            Detail             = $detail
            SentCount          = 1 + $sentArray.Count
            SentCertificates   = @(@($Leaf) + $sentArray | ForEach-Object { Get-SimpleName $_ })
            ChainPath          = @($path | ForEach-Object { Get-SimpleName $_ })
            RootSent           = $rootSent
            UnusedCertificates = $unused
            ChainStatus        = $statusNames
            LeafSubject        = $Leaf.Subject
            LeafIssuer         = $Leaf.Issuer
            LeafNotAfter       = $Leaf.NotAfter
        }
        if ($missing) {
            $result.MissingIssuer = $missing.Subject
            $result.MissingIssuerKeyId = $missing.KeyId
            $result.MissingIssuerAia = [string[]]@($missing.Aia | Where-Object { $_ })
            $result.MissingIssuerAvailableLocally = $missing.AvailableLocally
        }
        New-AnalysisResult @result
    }

    function Get-TlsServerCertificate {
        param(
            [Parameter(Mandatory)][string]$HostName,
            [Parameter(Mandatory)][int]$Port,
            [Parameter(Mandatory)][int]$TimeoutSeconds
        )

        $captured = @{ Leaf = $null; Others = @() }
        # Accept any certificate: the handshake only collects what the server sends, and no data is exchanged.
        $callback = {
            param($source, $certificate, $chain, $policyErrors)
            if ($certificate) {
                $captured.Leaf = [X509Certificate2]::new($certificate.GetRawCertData())
            }
            if ($chain) {
                $captured.Others = @($chain.ChainPolicy.ExtraStore | ForEach-Object { [X509Certificate2]::new($_.RawData) })
            }
            $true
        }.GetNewClosure()

        $timeoutMs = $TimeoutSeconds * 1000
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ssl = $null
        try {
            $connect = $tcp.ConnectAsync($HostName, $Port)
            if (-not $connect.Wait($timeoutMs)) {
                throw "Timed out connecting to ${HostName}:$Port after $TimeoutSeconds second(s)."
            }
            $tcp.ReceiveTimeout = $timeoutMs
            $tcp.SendTimeout = $timeoutMs

            $options = [System.Net.Security.SslClientAuthenticationOptions]::new()
            $options.TargetHost = $HostName
            $options.CertificateRevocationCheckMode = [X509RevocationMode]::NoCheck
            $options.RemoteCertificateValidationCallback = $callback

            # The synchronous handshake keeps the callback on this runspace's thread.
            $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
            $handshakeError = $null
            try {
                $ssl.AuthenticateAsClient($options)
            }
            catch {
                $handshakeError = $_.Exception.GetBaseException().Message
            }

            if (-not $captured.Leaf) {
                throw "TLS handshake failed before the server certificate was received: $handshakeError"
            }
            [pscustomobject]@{
                Leaf           = $captured.Leaf
                Others         = [X509Certificate2[]]$captured.Others
                Protocol       = if ($handshakeError) { $null } else { [string]$ssl.SslProtocol }
                HandshakeError = $handshakeError
            }
        }
        finally {
            if ($ssl) { $ssl.Dispose() }
            $tcp.Dispose()
        }
    }

    function New-HostResult {
        param([string]$HostName, [int]$Port, [pscustomobject]$Analysis, [string]$Protocol, $HostnameMatches, [string]$ErrorMessage)

        $properties = [ordered]@{ HostName = $HostName; Port = $Port }
        foreach ($property in $Analysis.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        $properties.Protocol = $Protocol
        $properties.HostnameMatches = $HostnameMatches
        $properties.Error = $ErrorMessage

        $result = [pscustomobject]$properties
        $defaultView = [System.Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet', [string[]]@('HostName', 'Port', 'Status', 'SentCount', 'MissingIssuer'))
        $result | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($defaultView))
        $result
    }

    if ([string]::IsNullOrWhiteSpace($RootCaBundle)) {
        throw 'No root CA bundle specified. Use -RootCaBundle or set the TLSCHECKER_ROOT_BUNDLE environment variable to the path of a PEM file.'
    }
    $trustedRoots = Import-RootCaBundle -Path $RootCaBundle
    Write-Verbose "Root CA bundle: $RootCaBundle"
    Write-Verbose "Trusted roots: $(($trustedRoots | ForEach-Object { $_.Subject }) -join '; ')"
    $anyNonCompliant = $false
}

process {
    foreach ($entry in $HostName) {
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry.TrimStart().StartsWith('#')) { continue }

        try {
            $target = Split-HostEntry -Entry $entry -DefaultPort $Port
        }
        catch {
            Write-Error -Message $_.Exception.Message -TargetObject $entry
            $anyNonCompliant = $true
            continue
        }

        Write-Verbose "Checking $($target.HostName):$($target.Port)"
        try {
            $server = Get-TlsServerCertificate -HostName $target.HostName -Port $target.Port -TimeoutSeconds $TimeoutSeconds
        }
        catch {
            $message = $_.Exception.GetBaseException().Message
            $analysis = New-AnalysisResult -Status 'ConnectionFailed' -Detail "Could not retrieve the server certificates: $message"
            New-HostResult -HostName $target.HostName -Port $target.Port -Analysis $analysis -ErrorMessage $message
            $anyNonCompliant = $true
            continue
        }

        $analysis = Test-CertificateChainCompliance -Leaf $server.Leaf -ServerCertificates $server.Others -TrustedRoots $trustedRoots
        $hostnameMatches = try { $server.Leaf.MatchesHostname($target.HostName) } catch { $null }
        New-HostResult -HostName $target.HostName -Port $target.Port -Analysis $analysis `
            -Protocol $server.Protocol -HostnameMatches $hostnameMatches -ErrorMessage $server.HandshakeError
        if (-not $analysis.IsCompliant) { $anyNonCompliant = $true }
    }
}

end {
    if ($anyNonCompliant) { exit 1 }
}
 