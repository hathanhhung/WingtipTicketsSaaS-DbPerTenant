<#
.SYNOPSIS
  Restores tenant servers in origin Wingtip region to recovery region

.DESCRIPTION
  This script is intended to be run as a background job in the 'Restore-IntoSecondaryRegion' script that recovers the Wingtip SaaS app environment (apps, databases, servers e.t.c) into a recovery region.
  The script creates tenant servers that will be used to host tenant databases restored from the primary Wingtip location.

.PARAMETER WingtipRecoveryResourceGroup
  Resource group that will be used to contain recovered resources

.EXAMPLE
  [PS] C:\>.\Restore-TenantServersToRecoveryRegion.ps1 -WingtipRecoveryResourceGroup "sampleRecoveryResourceGroup"
#>
[cmdletbinding()]
param (
    [parameter(Mandatory=$true)]
    [String] $WingtipRecoveryResourceGroup
)

Import-Module "$using:scriptPath\..\..\Common\CatalogAndDatabaseManagement" -Force
Import-Module "$using:scriptPath\..\..\WtpConfig" -Force
Import-Module "$using:scriptPath\..\..\UserConfig" -Force

# Stop execution on error 
$ErrorActionPreference = "Stop"
  
# Login to Azure subscription
$credentialLoad = Import-AzureRmContext -Path "$env:TEMP\profile.json"
if (!$credentialLoad)
{
    Initialize-Subscription
}

# Get deployment configuration  
$wtpUser = Get-UserConfig
$config = Get-Configuration

# Get the active tenant catalog 
$tenantCatalog = Get-Catalog -ResourceGroupName $wtpUser.ResourceGroupName -WtpUser $wtpUser.Name

# Get the recovery region resource group
$recoveryResourceGroup = Get-AzureRmResourceGroup -Name $WingtipRecoveryResourceGroup

[String[]]$serverQueue = @()
[String[]]$tenantAdmins = @()
[String[]]$tenantAdmminPasswords = @()
$recoveredServers = 0
$sleepInterval = 10
$pastDeploymentWaitTime = 0
$deploymentName = "TenantServerRecovery"

# Find any previous server recovery operations to get most current state of recovered resources 
# This allows the script to be re-run if an error during deployment 
$pastDeployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $WingtipRecoveryResourceGroup -Name $deploymentName -ErrorAction SilentlyContinue 2>$null

# Wait for past deployment to complete if it's still active 
while (($pastDeployment) -and ($pastDeployment.ProvisioningState -NotIn "Succeeded", "Failed", "Canceled"))
{
  # Wait for no more than 5 minutes (300 secs) for previous deployment to complete
  if ($pastDeploymentWaitTime -lt 300)
  {
      Write-Output "Waiting for previous deployment to complete ..."
      Start-Sleep $sleepInterval
      $pastDeploymentWaitTime += $sleepInterval
      $pastDeployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $WingtipRecoveryResourceGroup -Name $deploymentName -ErrorAction SilentlyContinue 2>$null    
  }
  else
  {
      Stop-AzureRmResourceGroupDeployment -ResourceGroupName $WingtipRecoveryResourceGroup -Name $deploymentName -ErrorAction SilentlyContinue 1>$null 2>$null
      break
  }
  
}

# Get list of servers to be recovered 
# Note: It is also possible to scope recovery to a smaller list of servers.
$serverList = @()
$serverList += Get-ExtendedServer -Catalog $tenantCatalog | Where-Object {($_.ServerName -NotMatch "$($config.RecoverySuffix)$")}
$restoredServers = Find-AzureRmResource -ResourceGroupNameEquals $WingtipRecoveryResourceGroup -ResourceType "Microsoft.sql/servers"

foreach ($server in $serverList)
{
  # Only recover servers that haven't already been recovered or haven't started repatriation
  $serverRecoveryName = $server.ServerName + $config.RecoverySuffix
  if (($server.RecoveryState -In "n/a","restoring","complete") -and ($restoredServers.Name -notcontains $serverRecoveryName))
  {
    $serverQueue += $serverRecoveryName
    $tenantAdmins += $config.TenantAdminUserName
    $tenantAdminPasswords += $config.TenantAdminPassword  

    # Mark servers in queue as recovering
    $serverState = Update-TenantResourceRecoveryState -Catalog $tenantCatalog -UpdateAction "startRecovery" -ServerName $server.ServerName
  }
  elseif (($server.RecoveryState -In "restoring") -and ($restoredServers.Name -contains $serverRecoveryName))
  {
    # Mark previously recovered servers
    $serverState = Update-TenantResourceRecoveryState -Catalog $tenantCatalog -UpdateAction "endRecovery" -ServerName $server.ServerName
    $recoveredServers += 1
  }
  elseif ($server.RecoveryState -In 'restored')
  {
    $recoveredServers += 1
  }
}
  
# Output recovery progress 
$serverRecoveryPercentage = [math]::Round($recoveredServers/$serverList.length,2)
$serverRecoveryPercentage = $serverRecoveryPercentage * 100
Write-Output "$serverRecoveryPercentage% ($($recoveredServers) of $($serverList.length))"


# Restore tenant servers and firewall rules in them 
# Note: In a production scenario you would additionally restore logins and users that existed in the primary server (see: https://docs.microsoft.com/en-us/azure/sql-database/sql-database-disaster-recovery)
if ($serverQueue.Count -gt 0)
{
  $deployment = New-AzureRmResourceGroupDeployment `
                  -Name "TenantServerRecovery" `
                  -ResourceGroupName $recoveryResourceGroup.ResourceGroupName `
                  -TemplateFile ("$using:scriptPath\RecoveryTemplates\" + $config.TenantServerRestoreBatchTemplate) `
                  -Location $recoveryResourceGroup.Location `
                  -ServerNames $serverQueue `
                  -adminLogins $tenantAdmins `
                  -adminPasswords $tenantAdminPasswords `
                  -ErrorAction Stop

  # Mark 'origin' servers as recovered 
  foreach ($server in $serverQueue)
  {
    $serverState = Update-TenantResourceRecoveryState -Catalog $tenantCatalog -UpdateAction "endRecovery" -ServerName ($_ -split $config.RecoverySuffix)[0]
  }
  $recoveredServers += $serverQueue.Length
}

# Output recovery progress 
$serverRecoveryPercentage = [math]::Round($recoveredServers/$serverList.length,2)
$serverRecoveryPercentage = $serverRecoveryPercentage * 100
Write-Output "$serverRecoveryPercentage% ($($recoveredServers) of $($serverList.length))"
