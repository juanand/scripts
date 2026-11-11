# Agent Instructions

## Purpose

[Test-TlsCertificateChain.ps1](./Test-TlsCertificateChain.ps1) checks whether HTTPS servers send every intermediate CA certificate needed to reach a trusted root. [README.md](./README.md) is the specification: its The Problem, Compliance Rules, and Remediation sections explain the root cause and the expected results. Keep the README in sync with script changes.

The script must work with any internal PKI, not only the hierarchy used by the live sample hosts.

## Build and test

There is no build step. Tests use Pester 5:

```powershell
Invoke-Pester -Path .\tests                                         # offline tests
Invoke-Pester -Path .\tests -FullNameFilter '*multi-level chain*'   # single test
$env:TLSCHECKER_ROOT_BUNDLE = 'C:\path\to\roots.pem'
Invoke-Pester -Path .\tests -TagFilter Live                         # live sample hosts
```

Live tests are skipped unless `TLSCHECKER_ROOT_BUNDLE` points to a PEM root bundle. The script reads the same variable, so the live tests don't pass `-RootCaBundle`. Export the root CA with `(Get-Item Cert:\LocalMachine\Root\<thumbprint>).ExportCertificatePem()`. Keep the bundle outside the repository.

## Architecture

The script is a single file, so operators can copy it anywhere. Its helper functions live in the `begin` block:

* `Get-TlsServerCertificate` performs the TLS handshake and captures what the server sent.
* `Test-CertificateChainCompliance` is pure logic with no network access. Put chain rules here so offline tests can cover them.
* `Import-RootCaBundle` loads the root CA bundle, and `Split-HostEntry` parses host entries.

The tests don't dot-source the script, because that would run its main body. Instead, they parse it with the PowerShell AST and load each function definition together with the script's `using` statements. A new helper therefore becomes available to the tests automatically, but it must not depend on variables set in the `begin` block.

## Domain model

```text
Root CA                     (client trust store only)
  +-- Issuing CA            (server must send this)
        +-- <leaf>          (server sends this)
```

A host is compliant when the configured roots can be reached using only the certificates the server sent. A correct server must not depend on intermediates installed on the client or downloaded through AIA.

## Behavior verified on Windows

These behaviors were observed on a development machine with issuing CAs in its local intermediate store. The design depends on them:

* Inside the `SslStream` validation callback, `chain.ChainPolicy.ExtraStore` holds only the non-leaf certificates the server sent. This works with TLS 1.2 and TLS 1.3, so no raw handshake parsing is needed. The order of `ExtraStore` doesn't follow the handshake order.
* A strict `X509Chain` (`CustomRootTrust`, `DisableCertificateDownloads`) still uses intermediates from the local Windows certificate stores. Chain validity alone isn't enough: `Test-CertificateChainCompliance` must also check that each intermediate in the built path was sent by the server.
* Use the synchronous `AuthenticateAsClient`. A PowerShell scriptblock callback can't run on the thread pool thread that the async handshake uses.

## Conventions

* Target PowerShell 7.4+ (`#Requires -Version 7.4`): `ImportFromPemFile`, `MatchesHostname`, and the AKI and AIA extension types require .NET 7 or later. Windows PowerShell 5.1 is out of scope; the README explains why.
* Use only PowerShell and .NET. Don't call `openssl.exe`. If a check ever requires it, document OpenSSL as a prerequisite in the script help and the README.
* `-RootCaBundle` defaults to `$env:TLSCHECKER_ROOT_BUNDLE`, and an explicit parameter overrides it. Keep the parameter non-mandatory so PowerShell doesn't prompt, and fail in the `begin` block with a message naming both options when neither is set.
* Don't hardcode CA names, distinguished names, thumbprints, or AIA URLs in the script. Keep documentation, this file, examples, and tests free of organization-specific CA names, host names, and configurations; use generic names such as `Root CA`, `Issuing CA 1`, and `app1.example.local`.
* Match certificates by subject and public key, not by thumbprint or name alone. This treats a re-issued CA as equivalent and a renewed CA with a new key as different.
* Never download from AIA to decide a result. Report AIA URLs only as diagnostics for the missing issuer.
* Status precedence is `MissingIntermediate`, `UntrustedRoot`, `InvalidChain`, then `Compliant`. Sending the root or unrelated certificates is reported but isn't a failure, as allowed by RFC 5246 section 7.4.2 and RFC 8446 section 4.4.2. The README's Compliance Rules section quotes both. Update it if these rules change.
* Cover new chain scenarios with offline tests that generate certificates with `CertificateRequest`. Use unique subject names for each run so the Windows chain engine can't reuse cached certificates.
* In PowerShell, call .NET extension methods as static methods, for example `[RSACertificateExtensions]::CopyWithPrivateKey($cert, $key)`. Without its private key, a generated CA can't sign child certificates.
* The `X509AuthorityInformationAccessExtension` constructor takes OCSP URLs first and CA issuer URLs second.
 