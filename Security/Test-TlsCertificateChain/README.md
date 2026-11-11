\---

title: Test-TlsCertificateChain.ps1

description: PowerShell script that detects internal HTTPS servers that do not send their intermediate CA certificates during the TLS handshake

\---

\## Overview



The \[Test-TlsCertificateChain.ps1](./Test-TlsCertificateChain.ps1) script is a human-tested, vibe-coded PowerShell 7 script to check internal HTTPS endpoints for certificate validation compliance.



It reports whether each server sends the full certificate chain: its leaf certificate plus every intermediate CA needed to reach a trusted root. Servers that omit an intermediate fail validation on clients that trust only the root CA. This is common on Linux, OpenSSL, and containers.



The checker doesn't depend on a specific PKI. You provide the trusted root CAs as a PEM bundle, and the script works out which intermediates each server must send. It supports multiple roots, multiple issuing CAs, and chains with more than one intermediate level.



See \[The Problem](#the-problem) for why missing intermediates break some clients but not others, and \[Remediation](#remediation) for how to fix affected servers.



\## Requirements



\* PowerShell 7.4 or later (`pwsh`).

\* A PEM file with the trusted root CA certificates, passed with `-RootCaBundle` or the `TLSCHECKER\_ROOT\_BUNDLE` environment variable.

\* No OpenSSL binaries are required. The checks use only PowerShell and .NET.

\* Pester 5 is needed only to run the tests.



\### Windows PowerShell 5.1 Limitation



Windows PowerShell 5.1 is not supported. It runs on .NET Framework, which lacks the APIs required to replicate a "Root only" client:



\* `X509ChainPolicy.TrustMode` and `CustomTrustStore` for trusting only the root CA.

\* `X509ChainPolicy.DisableCertificateDownloads` for blocking AIA retrieval of missing intermediates.



Without these APIs, the Windows chain engine fills in missing intermediates from the local certificate store or from AIA, so a misconfigured server can appear valid. See \[Why Some Clients Still Succeed](#why-some-clients-still-succeed).



\## Usage



Check one or more hosts:



```powershell

.\\Test-TlsCertificateChain.ps1 -HostName app1.example.local, app2.example.local -RootCaBundle .\\roots.pem

```



Check a list of hosts from a file, one per line. Blank lines and lines starting with `#` are skipped. This example takes the root CA bundle from the `TLSCHECKER\_ROOT\_BUNDLE` environment variable:



```powershell

$env:TLSCHECKER\_ROOT\_BUNDLE = 'C:\\pki\\roots.pem'

Get-Content .\\hosts.txt | .\\Test-TlsCertificateChain.ps1 | Format-List \*

```



Each entry can be a host name, an IP address, `host:port`, `\[IPv6]:port`, or an `https://` URL. Use `-Port` to change the default port (443) and `-TimeoutSeconds` to change the connection timeout (10 seconds).



\### Root CA Bundle



The script reads the trusted roots from a PEM file. It looks for the path in this order:



1\. The `-RootCaBundle` parameter.

2\. The `TLSCHECKER\_ROOT\_BUNDLE` environment variable.



If neither is set, the script stops with an error. Set the variable once per session, or in your profile, to avoid passing the path on every run.



The bundle contains one or more `BEGIN CERTIFICATE` blocks. Only self-signed root certificates are used. The script ignores any intermediate in the file with a warning, because trusting an intermediate would hide servers that don't send it.



To export a root from the Windows certificate store:



```powershell

(Get-Item Cert:\\LocalMachine\\Root\\<thumbprint>).ExportCertificatePem() | Set-Content .\\roots.pem

```



\### Output



The script returns one object per host. The default view shows `HostName`, `Port`, `Status`, `SentCount`, and `MissingIssuer`. Use `Format-List \*` to see every property.



| Status                  | Meaning                                                                                  |

| ----------------------- | ---------------------------------------------------------------------------------------- |

| `Compliant`           | The server sends every intermediate, and the chain reaches a root in the bundle.         |

| `MissingIntermediate` | The server doesn't send an intermediate it needs. `MissingIssuer` identifies it.       |

| `UntrustedRoot`       | The chain is complete but ends at a root that isn't in the bundle.                       |

| `InvalidChain`        | The chain fails for another reason, such as an expired certificate. See `ChainStatus`. |

| `ConnectionFailed`    | The script couldn't retrieve the server certificates. See `Error`.                     |



Other useful properties:



\* `SentCount` is the number of certificates the server sent, including the leaf. It matches the number of entries `openssl s\_client -showcerts` lists.

\* `MissingIssuerKeyId` and `MissingIssuerAia` identify the missing CA by key identifier and download URL. They help service owners find the right certificate.

\* `MissingIssuerAvailableLocally` is `True` when this machine has a copy of the missing intermediate. Browsers and Windows tools on this machine then accept the server, even though Linux clients don't.

\* `RootSent` and `UnusedCertificates` report extra certificates the server sends. Neither is a failure on its own. See \[Compliance Rules](#compliance-rules).

\* `HostnameMatches` shows whether the leaf certificate is valid for the host name. It doesn't affect `Status`.



The script exits with code 1 when any host isn't `Compliant`, so you can use it in pipelines and scheduled jobs. It doesn't check revocation and sends no application data.



To export the results to a CSV file, join the array properties, such as `SentCertificates`, `ChainPath`, and `ChainStatus`, first. Otherwise `Export-Csv` writes them as `System.String\[]`:



```powershell

Get-Content .\\hosts.txt |

&#x20;   .\\Test-TlsCertificateChain.ps1 |

&#x20;   ForEach-Object {

&#x20;       $row = \[ordered]@{}

&#x20;       foreach ($property in $\_.PSObject.Properties) {

&#x20;           $row\[$property.Name] = if ($property.Value -is \[array]) { $property.Value -join '; ' } else { $property.Value }

&#x20;       }

&#x20;       \[pscustomobject]$row

&#x20;   } |

&#x20;   Export-Csv .\\tls-results.csv -NoTypeInformation

```



\## The Problem



A typical internal PKI has at least two levels:



```text

Root CA                     (installed in client trust store)

+-- Issuing CA             (intermediate: the server must send it)

&#x20;    +-- Server certificate (leaf: the server sends it)

```



Clients trust only the root CA, for example through `/etc/ssl/certs/ca-certificates.crt` on Linux or the Trusted Root Certification Authorities store on Windows. To validate a server, the client must build a path from the leaf certificate to that root. The leaf names its issuing CA, but the client usually doesn't have the issuing CA certificate. The server must provide it.



A correctly configured server sends the leaf and the issuing CA. The client completes the path with its own copy of the root:



```text

Server certificate -> Issuing CA (sent by the server) -> Root CA (client trust store)

```



A misconfigured server sends only the leaf. The client can't find the issuing CA and stops:



```text

Server certificate -> Issuing CA (missing)

```



OpenSSL-based clients report this as:



```text

verify error:num=20:unable to get local issuer certificate

verify error:num=21:unable to verify the first certificate

```



The root cause is on the server: it is configured with the leaf certificate alone instead of the full chain. The root CA trust on the clients is correct.



\### Why Some Clients Still Succeed



The same server can work on one machine and fail on another. Several client-side mechanisms hide a missing intermediate:



\* The intermediate is installed on the client. The client then finds the issuing CA in its local store instead of receiving it from the server. This masks the server defect. It's a workaround, not a fix.

\* The client downloads the intermediate. Server certificates usually contain an Authority Information Access (AIA) URL that points to the issuing CA certificate (\[RFC 5280, section 4.2.2.1](https://www.rfc-editor.org/rfc/rfc5280#section-4.2.2.1)). Windows CryptoAPI and Schannel may download it automatically. OpenSSL, curl built with OpenSSL, wget, nginx, HAProxy, and most Linux TLS stacks don't. A server that omits its intermediate can therefore work from Windows and fail from Linux.

\* Tools use different trust stores, even on the same machine:



| Tool                             | Typical trust source                                                                                                                                                                                         |

| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |

| Edge, Chrome on Windows          | Windows certificate store                                                                                                                                                                                    |

| PowerShell (`Invoke-WebRequest`) | Windows certificate store, through Schannel                                                                                                                                                                  |

| curl on Windows                  | Usually Schannel and the Windows certificate store, unless overridden with `--cacert`. `CURL\_CA\_BUNDLE` and `SSL\_CERT\_FILE` apply only to curl builds that use OpenSSL. Run `curl -V` to see the TLS backend |

| OpenSSL                          | Its own CA bundle, unless overridden with the `SSL\_CERT\_FILE` environment variable or the `-CAfile` option                                                                                                   |



A successful connection from a browser or PowerShell doesn't prove that OpenSSL, Java, Python, Go, or a container will validate the same server. The reverse also happens: `openssl.exe` on Windows can fail even against a correctly configured server, because it doesn't read the Windows store and can't find the root. Point it at a PEM bundle with the root CA, then open a new command prompt:



```cmd

setx SSL\_CERT\_FILE C:\\path\\to\\root-ca-bundle.pem

```



When troubleshooting, identify two things separately: which certificates the server sends, and which trust store the client uses. The script reports the first one without relying on this machine's stores. `MissingIssuerAvailableLocally` shows when this machine would hide the problem.



\## Compliance Rules



A server is compliant when it sends its leaf certificate and every intermediate CA certificate needed to reach a trusted root. Sending the root is optional. These rules follow the TLS specifications for the server `Certificate` message.



\[RFC 5246, section 7.4.2](https://www.rfc-editor.org/rfc/rfc5246#section-7.4.2) (TLS 1.2):



> This is a sequence (chain) of certificates. The sender's certificate MUST come first in the list. Each following certificate MUST directly certify the one preceding it. Because certificate validation requires that root keys be distributed independently, the self-signed certificate that specifies the root certificate authority MAY be omitted from the chain, under the assumption that the remote end must already possess it in order to validate it in any case.



\[RFC 8446, section 4.4.2](https://www.rfc-editor.org/rfc/rfc8446#section-4.4.2) (TLS 1.3):



> The sender's certificate MUST come in the first CertificateEntry in the list. Each following certificate SHOULD directly certify the one immediately preceding it. Because certificate validation requires that trust anchors be distributed independently, a certificate that specifies a trust anchor MAY be omitted from the chain, provided that supported peers are known to possess any omitted certificates.



The script applies these rules as follows:



| Server sends                           | Result                                      | Basis                                                                                              |

| -------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------- |

| Leaf and every intermediate            | `Compliant`                               | The full chain up to the trust anchor is present.                                                  |

| Leaf, every intermediate, and the root | `Compliant`, with `RootSent` = `True` | The root "MAY be omitted", so sending it is allowed. It adds bytes and the client never trusts it. |

| Leaf only, or not every intermediate   | `MissingIntermediate`                     | Only the trust anchor may be omitted. Intermediates must be sent.                                  |

| Leaf, every intermediate, and extras   | `Compliant`, with `UnusedCertificates`  | RFC 8446 tells clients to tolerate extraneous certificates. They are reported, not failed.         |



RFC 8446 also notes that "for maximum compatibility, all implementations SHOULD be prepared to handle potentially extraneous certificates and arbitrary orderings". The script doesn't check certificate order, because .NET doesn't preserve the order in which the server sent the certificates.



The script never downloads intermediates from AIA. It reports the AIA URL only to help identify the missing certificate.



\## Remediation



Fix the server, not the clients. Each HTTPS service must send its leaf certificate followed by every intermediate CA certificate. Clients should need only the root CA in their trust store.



\### Server Configuration



1\. Install the server certificate and its private key.

2\. Obtain the intermediate CA certificates. `MissingIssuerAia` lists where to download them.

3\. Configure the service to send the full chain.

4\. Verify with this script or with OpenSSL, as described in \[Manual Verification](#manual-verification).



\#### NGINX



Use a full-chain file that contains the server certificate followed by the intermediates:



```nginx

ssl\_certificate     /etc/nginx/certs/fullchain.pem;

ssl\_certificate\_key /etc/nginx/certs/server.key;

```



\#### Apache HTTP Server



Point `SSLCertificateFile` to the same kind of full-chain file:



```apache

SSLCertificateFile    /path/to/fullchain.pem

SSLCertificateKeyFile /path/to/server.key

```



\#### Microsoft IIS



Install the intermediate certificates in the Intermediate Certification Authorities store of the local computer on the server. IIS builds the chain it sends from that store.



\#### F5 BIG-IP



Import the server certificate and the intermediates, and associate both with the client SSL profile.



\#### Kubernetes and OpenShift



The `tls.crt` entry of the TLS secret must contain the server certificate followed by the intermediates, not only the leaf.



\### Manual Verification



Without this script, you can inspect a server with OpenSSL:



```bash

openssl s\_client -connect <hostname>:443 -servername <hostname> -showcerts

```



A correctly configured server lists the leaf and each intermediate:



```text

Certificate chain

0 s:<server certificate>

1 s:<issuing CA>

...

Verify return code: 0 (ok)

```



If only certificate `0` appears, the server doesn't send its intermediate. `Verify return code: 0 (ok)` also requires OpenSSL to find the root CA. On Windows, set `SSL\_CERT\_FILE` as shown in \[Why Some Clients Still Succeed](#why-some-clients-still-succeed).



\### Recommended Practices



\* Trust only root CAs on clients, including Linux systems and container images.

\* Don't deploy intermediate CAs to clients as a permanent workaround.

\* Treat a missing intermediate as a server configuration defect that the service owner must fix. Raise remediation tickets as non-compliant services are found.

\* Check certificate-chain compliance when onboarding new services, for example by running this script in the onboarding process.



\## Tests



Run the offline tests:



```powershell

Invoke-Pester -Path .\\tests

```



Run a single test by name:



```powershell

Invoke-Pester -Path .\\tests -FullNameFilter '\*multi-level chain\*'

```



The offline tests generate their own certificate hierarchy, so they don't need network access or any real CA. They cover a second issuing CA under the same root, multi-level chains, wrong or stale intermediates, extra roots, and untrusted roots.



The live tests connect to real sample hosts and check that each result matches the expected one. They are skipped unless `TLSCHECKER\_ROOT\_BUNDLE` points to a root CA bundle:



```powershell

$env:TLSCHECKER\_ROOT\_BUNDLE = 'C:\\path\\to\\roots.pem'

Invoke-Pester -Path .\\tests -TagFilter Live

```

&#x20;

