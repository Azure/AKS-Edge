function Get-WindowsVmIpAddress
{
    $env:WSSD_CONFIG_PATH="c:\programdata\aksedge\protected\.wssd\cloudconfig"
    $WindowsVmTag="eb28e4f7-6522-4c33-a531-cfedf24b08e6"
    $IdLine = & 'C:\Program Files\aksedge\nodectl' network vnic list --query "[?tags.keys(@).contains(@,'$WindowsVmTag')]" | Select-String -Pattern "ipaddress:"
    $vmIp = ($IdLine -split ":")[1].Trim()

    return $vmIP
}

function Invoke-WindowsSSH
{
    param (
        [Parameter(Mandatory)]
        [String] $command
    )

    $vmIP = Get-WindowsVmIpAddress

    try
    {
        $sshPrivKey = New-SshPrivateKey

        & ssh.exe -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectionAttempts=10 -o ConnectTimeout=30 -o PasswordAuthentication=no -i "$sshPrivKey" "aksedge-user@$vmIp" $command
    }
    finally
    {
        Remove-Item -Path $sshPrivKey -Force -ErrorAction SilentlyContinue
    }
}

function New-SshPrivateKey
{

    $SshPrivateKey = $([io.Path]::Combine("C:\ProgramData\AksEdge\protected\.sshkey", "id_ecdsa"))
    if(!(Test-Path -Path $SshPrivateKey))
    {
        Throw $("'$SshPrivateKey' is not found")
    }

    $TempFile = New-TemporaryFile
    Copy-Item $SshPrivateKey $TempFile

    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $NewOwner = New-Object -TypeName System.Security.Principal.NTAccount -ArgumentList $CurrentUser

    $acl = Get-Acl $TempFile
    $acl.SetOwner($NewOwner)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($NewOwner, "FullControl", "allow")
    $acl.AddAccessRule($rule)
    $acl | Set-Acl

    return $TempFile
}
