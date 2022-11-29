<#
    .DESCRIPTION
        This function uses Ping requests (ICMP) to discover devices on the network. Each Ping traffic is used to generate the arp-cache table. 
#>

Write-Host "WARNING: This tool uses ICMP & ARP requests to discover free network IP addresses. Firewalls may block these requests, limiting the use of the tool. If possible, please do a manual network check of your DHCP server or IP address allocation table." -ForegroundColor Yellow
Write-Host "`n1. Listing network adapters..." -ForegroundColor Green

# Print all the network adapters
Get-NetAdapter

do 
{
  Write-Host "`n2. Select ifIndex of desired network adapter scan:" -ForegroundColor Green
  $inputString = read-host
  $ifIndex = $inputString -as [Int]
  $ifIndexOk = $ifIndex -ne $NULL -and (Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue) -ne $NULL
  if ( -not $ifIndexOk ) { Write-Host "Error: You must enter a valid ifIndex" -ForegroundColor Red }
}
until ( $ifIndexOk )

Write-Host "`n3. Selected adapter:  $($(Get-NetAdapter -InterfaceIndex $ifIndex).Name)" -ForegroundColor Green

# Ensure the adapter has a valid IP address and network range
$netIpConfig =  Get-NetIPConfiguration | Where-Object {$_.InterfaceIndex -eq $ifIndex}
if(!$netIpConfig)
{
    Write-Host "Error: $($(Get-NetAdapter -InterfaceIndex $ifIndex).Name) does not have a valid IP address. Please try again with another network adapter, or check your networking configurations." -ForegroundColor Red
    # Display message for 10s and then close
    Start-Sleep -Seconds 10
    return
}

# Ping all the addresses of the range
$netIpConfig.IPv4DefaultGateway.NextHop | % { 
    $netip="$($([IPAddress]$_).GetAddressBytes()[0]).$($([IPAddress]$_).GetAddressBytes()[1]).$($([IPAddress]$_).GetAddressBytes()[2])"
    Write-Host "Ping C-Subnet $netip.1-254 ..." -ForegroundColor Yellow
    1..254 | % { 
        (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$netip.$_","1000") | Out-Null
    }
}

# Wait until arp-cache: complete
while ($(Get-NetNeighbor).state -eq "incomplete") {
	Write-host "Waiting..." -ForegroundColor Yellow
	timeout 1 | Out-Null
}

# Print all the arp-cache entries
Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $ifIndex | Where-Object -Property state -ne Unreachable | select IPaddress,LinkLayerAddress,State, @{n="Hostname"; e={(Resolve-DnsName $_.IPaddress).NameHost}} | Out-GridView

if ($Host.Name -eq "ConsoleHost")
{
    Write-Host "`n4. Press any key to continue..." -ForegroundColor Green
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp") > $null
}
