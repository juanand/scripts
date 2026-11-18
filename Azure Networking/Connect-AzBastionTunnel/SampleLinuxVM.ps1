.\Connect-AzBastionTunnel.ps1 `
-BastionSubscription $SubscriptionName `
-BastionName $ResourceGroup `
-BastionResourceGroup $BastionName `
-TargetIpAddress $IPAddress `
-username $username `
-Protocol SSH
