﻿<#
.SYNOPSIS
Remove any artifacts that remain of the given resource

.DESCRIPTION
Remove any artifacts that remain of the given resource. For example, some resources such as key vaults usually go into a soft-delete state from which we want to purge them from.

.PARAMETER resourceToRemove
Mandatory. The resource to remove. Should have format
@{
    name        = '...'
    resourceID = '...'
    type        = '...'
}

.EXAMPLE
Invoke-ResourcePostRemoval -resourceToRemove @{ name = 'myVault'; resourceId '(..)/Microsoft.KeyVault/vaults/myVault'; type = 'Microsoft.KeyVault/vaults'}

Purge resource 'myVault' of type 'Microsoft.KeyVault/vaults' if no purge protection is enabled
#>
function Invoke-ResourcePostRemoval {

    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [hashtable] $resourceToRemove
    )

    switch ($resourceToRemove.type) {
        'Microsoft.KeyVault/vaults' {
            $name = $resourceToRemove.resourceId.Split('/')[-1]
            $resourceGroupName = $resourceToRemove.resourceId.Split('/')[4]

            $matchingKeyVault = Get-AzKeyVault -InRemovedState | Where-Object { $_.VaultName -eq $name -and $resourceGroupName -eq $resourceGroupName }
            if ($matchingKeyVault -and -not $resource.EnablePurgeProtection) {
                Write-Verbose "Purging key vault [$name]" -Verbose
                if ($PSCmdlet.ShouldProcess(('Key Vault with ID [{0}]' -f $matchingKeyVault.Id), 'Purge')) {
                    $null = Remove-AzKeyVault -ResourceId $matchingKeyVault.Id -InRemovedState -Force -Location $matchingKeyVault.Location
                }
            }
        }
        'Microsoft.CognitiveServices/accounts' {
            $name = $resourceToRemove.resourceId.Split('/')[-1]
            $resourceGroupName = $resourceToRemove.resourceId.Split('/')[4]

            $matchingAccount = Get-AzCognitiveServicesAccount -InRemovedState | Where-Object { $_.AccountName -eq $name -and $resourceGroupName -eq $resourceGroupName }
            if ($matchingAccount) {
                Write-Verbose "Purging cognitive services account [$name]" -Verbose
                if ($PSCmdlet.ShouldProcess(('Cognitive services account with ID [{0}]' -f $matchingAccount.Id), 'Purge')) {
                    $null = Remove-AzCognitiveServicesAccount -InRemovedState -Force -Location
                }
            }
        }
        'Microsoft.ApiManagement/service' {
            $apiManagementService = Get-AzResource -ResourceId $resourceToRemove.resourceId
            $requestInputObject = @{
                Method  = 'DELETE'
                Uri     = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.ApiManagement/locations/{1}/deletedservices/{2}?api-version=2020-06-01-preview' -f $apiManagementService.SubscriptionId, $apiManagementService.Location, $apiManagementService.Name
                Headers = @{
                    Authorization = 'Bearer {0}' -f (Get-AzAccessToken).Token
                }
            }
            Invoke-RestMethod @requestInputObject
        }
        'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems' {
            # Remove protected VM
            # Required if e.g. a VM was listed in an RSV and only that VM is removed
            $vaultId = $resourceToRemove.resourceId.split('/backupFabrics/')[0]
            $softDeleteStatus = (Get-AzRecoveryServicesVaultProperty -VaultId $vaultId).SoftDeleteFeatureState
            if ($softDeleteStatus -ne 'Disabled') {
                if ($PSCmdlet.ShouldProcess(('Soft-delete on RSV [{0}]' -f $vaultId), 'Set')) {
                    $null = Set-AzRecoveryServicesVaultProperty -VaultId $vaultId -SoftDeleteFeatureState 'Disable'
                }
            }

            $backupItemInputObject = @{
                BackupManagementType = 'AzureVM'
                WorkloadType         = 'AzureVM'
                VaultId              = $vaultId
                Name                 = $resourceToRemove.name
            }
            if ($backupItem = Get-AzRecoveryServicesBackupItem @backupItemInputObject -ErrorAction 'SilentlyContinue') {
                Write-Verbose ('Removing Backup item [{0}] from RSV [{1}]' -f $backupItem.Name, $vaultId) -Verbose

                if ($backupItem.DeleteState -eq 'ToBeDeleted') {
                    if ($PSCmdlet.ShouldProcess('Soft-deleted backup data removal', 'Undo')) {
                        $null = Undo-AzRecoveryServicesBackupItemDeletion -Item $backupItem -VaultId $vaultId -Force
                    }
                }

                if ($PSCmdlet.ShouldProcess(('Backup item [{0}] from RSV [{1}]' -f $backupItem.Name, $vaultId), 'Remove')) {
                    $null = Disable-AzRecoveryServicesBackupProtection -Item $backupItem -VaultId $vaultId -RemoveRecoveryPoints -Force
                }
            }

            # Undo a potential soft delete state change
            $null = Set-AzRecoveryServicesVaultProperty -VaultId $vaultId -SoftDeleteFeatureState $softDeleteStatus.TrimEnd('d')
        }
    }
}
