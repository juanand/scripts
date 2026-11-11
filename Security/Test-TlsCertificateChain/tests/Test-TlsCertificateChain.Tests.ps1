#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

BeforeDiscovery {
    $fixtureFolder = Join-Path $PSScriptRoot '..' 'test hosts'
    $liveFixtures = @(Get-ChildItem -LiteralPath $fixtureFolder -Filter '*.crt' | ForEach-Object {
            if ($_.BaseName -match '^(?<host>\S+) \[(?<label>[^\]]+)\]$') {
                @{ HostName = $Matches.host; Label = $Matches.label; ExpectCompliant = $Matches.label -eq 'Root Only OK' }
            }
        })
    $liveBundle = $env:TLSCHECKER_ROOT_BUNDLE
}

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'Test-TlsCertificateChain.ps1'

    # Load the script's helper functions without running its main body.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $usings = ($ast.UsingStatements | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($function in $functions) {
        . ([scriptblock]::Create($usings + [Environment]::NewLine + $function.Extent.Text))
    }

    function New-TestCertificate {
        param(
            [Parameter(Mandatory)][string]$Subject,
            [X509Certificate2]$Issuer,
            [switch]$CertificateAuthority,
            [string]$DnsName,
            [string]$AiaUrl,
            [datetime]$NotBefore = (Get-Date).AddDays(-1),
            [datetime]$NotAfter = (Get-Date).AddDays(30)
        )

        $key = [RSA]::Create(2048)
        $request = [CertificateRequest]::new($Subject, $key, [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([X509BasicConstraintsExtension]::new($CertificateAuthority.IsPresent, $false, 0, $true))
        $request.CertificateExtensions.Add([X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
        if ($CertificateAuthority) {
            $usage = [X509KeyUsageFlags]::KeyCertSign -bor [X509KeyUsageFlags]::CrlSign
            $request.CertificateExtensions.Add([X509KeyUsageExtension]::new($usage, $true))
        }
        if ($DnsName) {
            $san = [SubjectAlternativeNameBuilder]::new()
            $san.AddDnsName($DnsName)
            $request.CertificateExtensions.Add($san.Build())
        }
        if ($AiaUrl) {
            $request.CertificateExtensions.Add([X509AuthorityInformationAccessExtension]::new($null, [string[]]@($AiaUrl), $false))
        }

        if (-not $Issuer) {
            return $request.CreateSelfSigned($NotBefore, $NotAfter)
        }
        $request.CertificateExtensions.Add([X509AuthorityKeyIdentifierExtension]::CreateFromCertificate($Issuer, $true, $false))
        $serial = [byte[]]::new(16)
        [RandomNumberGenerator]::Fill($serial)
        $serial[0] = $serial[0] -band 0x7F
        $certificate = $request.Create($Issuer, $NotBefore, $NotAfter, $serial)
        [RSACertificateExtensions]::CopyWithPrivateKey($certificate, $key)
    }

    function New-Collection {
        param([X509Certificate2[]]$Certificate)
        $collection = [X509Certificate2Collection]::new()
        $collection.AddRange($Certificate)
        , $collection
    }

    $caLifetime = @{ NotBefore = (Get-Date).AddDays(-30); NotAfter = (Get-Date).AddYears(5) }
    # Unique names keep the Windows chain engine from finding these certificates in any cache or store.
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)

    $script:Root = New-TestCertificate -Subject "CN=Test Root $suffix" -CertificateAuthority @caLifetime
    $script:OtherRoot = New-TestCertificate -Subject "CN=Other Root $suffix" -CertificateAuthority @caLifetime
    $script:Issuer1 = New-TestCertificate -Subject "CN=Test Issuing CA 1 $suffix" -Issuer $Root -CertificateAuthority @caLifetime
    $script:Issuer2 = New-TestCertificate -Subject "CN=Test Issuing CA 2 $suffix" -Issuer $Root -CertificateAuthority @caLifetime
    $script:Issuer1Renewed = New-TestCertificate -Subject "CN=Test Issuing CA 1 $suffix" -Issuer $Root -CertificateAuthority @caLifetime
    $script:PolicyCa = New-TestCertificate -Subject "CN=Test Policy CA $suffix" -Issuer $Root -CertificateAuthority @caLifetime
    $script:DeepIssuer = New-TestCertificate -Subject "CN=Test Deep Issuer $suffix" -Issuer $PolicyCa -CertificateAuthority @caLifetime
    $script:ForeignIssuer = New-TestCertificate -Subject "CN=Foreign Issuer $suffix" -Issuer $OtherRoot -CertificateAuthority @caLifetime

    $aiaUrl = 'http://pki.invalid/Test%20Issuing%20CA%201.crt'
    $script:Leaf1 = New-TestCertificate -Subject 'CN=host1.test' -DnsName 'host1.test' -Issuer $Issuer1 -AiaUrl $aiaUrl
    $script:Leaf2 = New-TestCertificate -Subject 'CN=host2.test' -DnsName 'host2.test' -Issuer $Issuer2
    $script:LeafRenewed = New-TestCertificate -Subject 'CN=renewed.test' -DnsName 'renewed.test' -Issuer $Issuer1Renewed
    $script:LeafDeep = New-TestCertificate -Subject 'CN=deep.test' -DnsName 'deep.test' -Issuer $DeepIssuer
    $script:LeafForeign = New-TestCertificate -Subject 'CN=foreign.test' -DnsName 'foreign.test' -Issuer $ForeignIssuer
    $script:LeafExpired = New-TestCertificate -Subject 'CN=expired.test' -DnsName 'expired.test' -Issuer $Issuer1 `
        -NotBefore (Get-Date).AddDays(-20) -NotAfter (Get-Date).AddDays(-10)

    $script:Roots = New-Collection $Root
    $script:AiaUrl = $aiaUrl
}

Describe 'Test-CertificateChainCompliance' {
    It 'is compliant when the server sends the intermediate' {
        $result = Test-CertificateChainCompliance -Leaf $Leaf1 -ServerCertificates $Issuer1 -TrustedRoots $Roots

        $result.Status | Should -Be 'Compliant'
        $result.IsCompliant | Should -BeTrue
        $result.SentCount | Should -Be 2
        $result.ChainPath | Should -HaveCount 3
        $result.MissingIssuer | Should -BeNullOrEmpty
    }

    It 'reports the missing intermediate when the server sends only the leaf' {
        $result = Test-CertificateChainCompliance -Leaf $Leaf1 -ServerCertificates @() -TrustedRoots $Roots

        $result.Status | Should -Be 'MissingIntermediate'
        $result.IsCompliant | Should -BeFalse
        $result.SentCount | Should -Be 1
        $result.MissingIssuer | Should -Be $Issuer1.Subject
        $result.MissingIssuerKeyId | Should -Be $Issuer1.Extensions['2.5.29.14'].SubjectKeyIdentifier
        $result.MissingIssuerAia | Should -Be @($AiaUrl)
    }

    It 'handles a second issuing CA under the same root' {
        (Test-CertificateChainCompliance -Leaf $Leaf2 -ServerCertificates $Issuer2 -TrustedRoots $Roots).Status |
            Should -Be 'Compliant'
        (Test-CertificateChainCompliance -Leaf $Leaf2 -ServerCertificates @() -TrustedRoots $Roots).MissingIssuer |
            Should -Be $Issuer2.Subject
    }

    It 'detects a server that sends the wrong issuing CA' {
        $result = Test-CertificateChainCompliance -Leaf $Leaf1 -ServerCertificates $Issuer2 -TrustedRoots $Roots

        $result.Status | Should -Be 'MissingIntermediate'
        $result.MissingIssuer | Should -Be $Issuer1.Subject
        $result.UnusedCertificates | Should -Be @($Issuer2.Subject)
    }

    It 'detects a stale intermediate with the same name but a different key' {
        $result = Test-CertificateChainCompliance -Leaf $LeafRenewed -ServerCertificates $Issuer1 -TrustedRoots $Roots

        $result.IsCompliant | Should -BeFalse
        $result.Status | Should -BeIn @('MissingIntermediate', 'InvalidChain')
    }

    It 'requires every intermediate in a multi-level chain' {
        (Test-CertificateChainCompliance -Leaf $LeafDeep -ServerCertificates $DeepIssuer, $PolicyCa -TrustedRoots $Roots).Status |
            Should -Be 'Compliant'

        $partial = Test-CertificateChainCompliance -Leaf $LeafDeep -ServerCertificates $DeepIssuer -TrustedRoots $Roots
        $partial.Status | Should -Be 'MissingIntermediate'
        $partial.MissingIssuer | Should -Be $PolicyCa.Subject
    }

    It 'accepts a server that also sends the root, and reports it' {
        $result = Test-CertificateChainCompliance -Leaf $Leaf1 -ServerCertificates $Issuer1, $Root -TrustedRoots $Roots

        $result.Status | Should -Be 'Compliant'
        $result.RootSent | Should -BeTrue
    }

    It 'ignores a duplicate copy of the leaf in the server certificates' {
        $result = Test-CertificateChainCompliance -Leaf $Leaf1 -ServerCertificates $Leaf1, $Issuer1 -TrustedRoots $Roots

        $result.Status | Should -Be 'Compliant'
        $result.SentCount | Should -Be 2
    }

    It 'reports an untrusted root when the chain leads to a root outside the bundle' {
        $result = Test-CertificateChainCompliance -Leaf $LeafForeign -ServerCertificates $ForeignIssuer, $OtherRoot -TrustedRoots $Roots

        $result.Status | Should -Be 'UntrustedRoot'
        $result.Detail | Should -BeLike "*$($OtherRoot.Subject)*"
    }

    It 'supports bundles with more than one root' {
        $bothRoots = New-Collection $Root, $OtherRoot
        (Test-CertificateChainCompliance -Leaf $LeafForeign -ServerCertificates $ForeignIssuer -TrustedRoots $bothRoots).Status |
            Should -Be 'Compliant'
    }

    It 'reports other chain errors as InvalidChain' {
        $result = Test-CertificateChainCompliance -Leaf $LeafExpired -ServerCertificates $Issuer1 -TrustedRoots $Roots

        $result.Status | Should -Be 'InvalidChain'
        $result.ChainStatus | Should -Contain 'NotTimeValid'
    }
}

Describe 'Import-RootCaBundle' {
    BeforeAll {
        $script:BundleFolder = Join-Path ([IO.Path]::GetTempPath()) "tlschecker-tests-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $BundleFolder | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $BundleFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'loads every root from a PEM bundle' {
        $path = Join-Path $BundleFolder 'roots.pem'
        $Root.ExportCertificatePem() + "`n" + $OtherRoot.ExportCertificatePem() | Set-Content -LiteralPath $path

        $roots = Import-RootCaBundle -Path $path

        $roots.Count | Should -Be 2
    }

    It 'skips intermediates with a warning' {
        $path = Join-Path $BundleFolder 'mixed.pem'
        $Root.ExportCertificatePem() + "`n" + $Issuer1.ExportCertificatePem() | Set-Content -LiteralPath $path

        $roots = Import-RootCaBundle -Path $path -WarningVariable warnings -WarningAction SilentlyContinue

        $roots.Count | Should -Be 1
        $roots[0].Subject | Should -Be $Root.Subject
        $warnings | Should -HaveCount 1
    }

    It 'fails when the bundle contains no root' {
        $path = Join-Path $BundleFolder 'empty.pem'
        Set-Content -LiteralPath $path -Value 'not a certificate'

        { Import-RootCaBundle -Path $path } | Should -Throw '*No self-signed root*'
    }
}

Describe 'Split-HostEntry' {
    It 'parses <Entry>' -ForEach @(
        @{ Entry = 'host.local'; HostName = 'host.local'; Port = 443 }
        @{ Entry = ' host.local:8443 '; HostName = 'host.local'; Port = 8443 }
        @{ Entry = 'https://host.local/path'; HostName = 'host.local'; Port = 443 }
        @{ Entry = 'https://host.local:9443'; HostName = 'host.local'; Port = 9443 }
        @{ Entry = '[::1]:8443'; HostName = '::1'; Port = 8443 }
        @{ Entry = '10.0.0.1'; HostName = '10.0.0.1'; Port = 443 }
    ) {
        $target = Split-HostEntry -Entry $Entry -DefaultPort 443

        $target.HostName | Should -Be $HostName
        $target.Port | Should -Be $Port
    }

    It 'rejects an out-of-range port' {
        { Split-HostEntry -Entry 'host.local:70000' -DefaultPort 443 } | Should -Throw '*Invalid port*'
    }
}

Describe 'Script' {
    BeforeAll {
        $script:RootBundle = Join-Path ([IO.Path]::GetTempPath()) "tlschecker-root-$([guid]::NewGuid().ToString('N')).pem"
        $Root.ExportCertificatePem() | Set-Content -LiteralPath $RootBundle
    }

    AfterAll {
        Remove-Item -LiteralPath $RootBundle -Force -ErrorAction SilentlyContinue
    }

    It 'reports ConnectionFailed and exits with code 1 for an unreachable host' {
        $result = & $ScriptPath -HostName 'nonexistent.invalid' -RootCaBundle $RootBundle -TimeoutSeconds 5

        $LASTEXITCODE | Should -Be 1
        $result.Status | Should -Be 'ConnectionFailed'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'skips blank and comment lines from pipeline input' {
        $result = @('', '# comment', '   ') | & $ScriptPath -RootCaBundle $RootBundle

        $result | Should -BeNullOrEmpty
    }
}

Describe 'Root CA bundle resolution' {
    BeforeAll {
        $script:RootBundle = Join-Path ([IO.Path]::GetTempPath()) "tlschecker-root-$([guid]::NewGuid().ToString('N')).pem"
        $Root.ExportCertificatePem() | Set-Content -LiteralPath $RootBundle
        $script:MissingBundle = Join-Path ([IO.Path]::GetTempPath()) "tlschecker-missing-$([guid]::NewGuid().ToString('N')).pem"
    }

    BeforeEach {
        $script:SavedBundle = $env:TLSCHECKER_ROOT_BUNDLE
    }

    AfterEach {
        $env:TLSCHECKER_ROOT_BUNDLE = $SavedBundle
    }

    AfterAll {
        Remove-Item -LiteralPath $RootBundle -Force -ErrorAction SilentlyContinue
    }

    It 'uses TLSCHECKER_ROOT_BUNDLE when -RootCaBundle is omitted' {
        $env:TLSCHECKER_ROOT_BUNDLE = $RootBundle

        $result = & $ScriptPath -HostName 'nonexistent.invalid' -TimeoutSeconds 5 -Verbose 4>&1

        ($result | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }).Message |
            Should -Contain "Root CA bundle: $RootBundle"
        ($result | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Status |
            Should -Be 'ConnectionFailed'
    }

    It '-RootCaBundle overrides TLSCHECKER_ROOT_BUNDLE' {
        $env:TLSCHECKER_ROOT_BUNDLE = $MissingBundle

        $result = & $ScriptPath -HostName 'nonexistent.invalid' -RootCaBundle $RootBundle -TimeoutSeconds 5

        $result.Status | Should -Be 'ConnectionFailed'
    }

    It 'fails with guidance when neither is set' {
        $env:TLSCHECKER_ROOT_BUNDLE = $null

        { & $ScriptPath -HostName 'nonexistent.invalid' } | Should -Throw '*TLSCHECKER_ROOT_BUNDLE*'
    }
}

Describe 'Live fixture hosts' -Tag 'Live' {
    # The fixture file names supply the host names, and TLSCHECKER_ROOT_BUNDLE supplies the roots.
    It '<HostName> matches its fixture label [<Label>]' -ForEach $liveFixtures -Skip:(-not $liveBundle) {
        $result = & $ScriptPath -HostName $HostName

        $result.Status | Should -Not -Be 'ConnectionFailed'
        $result.IsCompliant | Should -Be $ExpectCompliant
        if (-not $ExpectCompliant) {
            $result.MissingIssuer | Should -Not -BeNullOrEmpty
        }
    }
}
 