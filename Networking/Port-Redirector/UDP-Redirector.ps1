param(
    [string]$LocalIP = "127.0.0.1",
    [int]$LocalPort = 53,
    [string]$RemoteHost = "8.8.8.8",
    [int]$RemotePort = 53
)

Add-Type -AssemblyName System.Net.Sockets
Add-Type -AssemblyName System.Threading

# Create cancellation token
$cancellationSource = [System.Threading.CancellationTokenSource]::new()
$token = $cancellationSource.Token

# Create local UDP socket
$localEndPoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($LocalIP), $LocalPort)
$udpClient = [System.Net.Sockets.UdpClient]::new($localEndPoint)

# Set socket to non-blocking mode
$udpClient.Client.Blocking = $false

Write-Host "Listening UDP on ${LocalIP}:${LocalPort} and redirecting to ${RemoteHost}:${RemotePort}"

# Handle Ctrl+C
Register-EngineEvent ConsoleCancelEventHandler -Action {
    Write-Host "`nStopping UDP redirector..."
    try {
        $udpClient.Close()
    } catch {
        Write-Host "Cleanup error: $_"
    }
    $cancellationSource.Cancel()
    exit 0
}

while (-not $token.IsCancellationRequested) {
    try {
        # Check if data is available
        if ($udpClient.Available -gt 0) {
            $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $data = $udpClient.Receive([ref]$remoteEP)

            Write-Host "Received ${data.Length} bytes from $($remoteEP.Address):$($remoteEP.Port)"

            # Forward to remote DNS server
            $udpForward = [System.Net.Sockets.UdpClient]::new()
            $udpForward.Connect($RemoteHost, $RemotePort)
            $udpForward.Client.ReceiveTimeout = 2000
            $udpForward.Send($data, $data.Length)

            # Receive response from remote DNS
            $remoteResponseEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $response = $udpForward.Receive([ref]$remoteResponseEP)

            Write-Host "Received ${response.Length} bytes from remote $($remoteResponseEP.Address):$($remoteResponseEP.Port)"

            # Send response back to original client
            $udpClient.Send($response, $response.Length, $remoteEP)
        } else {
            Start-Sleep -Milliseconds 100
        }
    }
    catch {
        # Ignore timeout or non-blocking errors
    }
}