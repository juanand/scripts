param(
    [string]$LocalIP = "127.0.0.1",
    [int]$LocalPort = 53,
    [string]$RemoteHost = "8.8.8.8",
    [int]$RemotePort = 53
)

# Remove old listener variable if exists
Remove-Variable listener -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Net.Sockets
Add-Type -AssemblyName System.Threading
Add-Type -AssemblyName System.Threading.Tasks

# Create cancellation token
$cancellationSource = [System.Threading.CancellationTokenSource]::new()
$token = $cancellationSource.Token

# Start listener
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($LocalIP), $LocalPort)
$listener.Start()
Write-Host "Listening on ${LocalIP}:${LocalPort} and redirecting to ${RemoteHost}:${RemotePort}"

# Handle Ctrl+C
Register-EngineEvent ConsoleCancelEventHandler -Action {
    Write-Host "`nStopping listener..."
    try {
        if ($listener -and $listener.Server) {
            $listener.Stop()
        }
    } catch {
        Write-Host "Listener cleanup error: $_"
    }
    $cancellationSource.Cancel()
    exit 0
}

while (-not $token.IsCancellationRequested) {
    if ($listener.Pending()) {
        $localClient = $listener.AcceptTcpClient()
        Write-Host "Client connected from $($localClient.Client.RemoteEndPoint)"

        $remoteClient = [System.Net.Sockets.TcpClient]::new($RemoteHost, $RemotePort)

        $localStream = $localClient.GetStream()
        $remoteStream = $remoteClient.GetStream()

        # Start bidirectional copy using CopyToAsync
        $task1 = $localStream.CopyToAsync($remoteStream, 8192, $token)
        $task2 = $remoteStream.CopyToAsync($localStream, 8192, $token)

        # Cast array to Task[] to avoid ambiguity
        $tasks = [System.Threading.Tasks.Task[]]@($task1, $task2)

        [System.Threading.Tasks.Task]::WhenAll($tasks).ContinueWith({
            try {
                $localStream.Close()
                $remoteStream.Close()
                $localClient.Close()
                $remoteClient.Close()
                Write-Host "Connection closed."
            } catch {
                Write-Host "Cleanup error: $_"
            }
        }) | Out-Null
    } else {
        Start-Sleep -Milliseconds 200
    }
}