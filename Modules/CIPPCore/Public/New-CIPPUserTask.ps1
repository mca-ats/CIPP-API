function New-CIPPUserTask {
    [CmdletBinding()]
    param (
        $UserObj,
        $APIName = 'New User Task',
        $TenantFilter,
        $Headers
    )
    $Results = [System.Collections.Generic.List[string]]::new()

    try {
        $CreationResults = New-CIPPUser -UserObj $UserObj -APIName $APIName -Headers $Headers
        $Results.Add('Created New User.')
        $Results.Add("Username: $($CreationResults.Username)")
        $Results.Add("Password: $($CreationResults.Password)")
    } catch {
        $Results.Add("Failed to create user. $($_.Exception.Message)" )
        return @{'Results' = $Results }
    }

    try {
        if ($UserObj.licenses.value) {
            if ($UserObj.sherwebLicense.value) {
                $License = Set-SherwebSubscription -Headers $Headers -TenantFilter $UserObj.tenantFilter -SKU $UserObj.sherwebLicense.value -Add 1
                $null = $results.Add('Added Sherweb License, scheduling assignment')
                $taskObject = [PSCustomObject]@{
                    TenantFilter  = $UserObj.tenantFilter
                    Name          = "Assign License: $UserPrincipalName"
                    Command       = @{
                        value = 'Set-CIPPUserLicense'
                    }
                    Parameters    = [pscustomobject]@{
                        UserId      = $UserObj.id
                        APIName     = 'Sherweb License Assignment'
                        AddLicenses = $licenses
                    }
                    ScheduledTime = 0 #right now, which is in the next 15 minutes and should cover most cases.
                    PostExecution = @{
                        Webhook = [bool]$Request.Body.PostExecution.webhook
                        Email   = [bool]$Request.Body.PostExecution.email
                        PSA     = [bool]$Request.Body.PostExecution.psa
                    }
                }
                Add-CIPPScheduledTask -Task $taskObject -hidden $false -Headers $Headers
            } else {
                $LicenseResults = Set-CIPPUserLicense -UserId $CreationResults.Username -TenantFilter $UserObj.tenantFilter -AddLicenses $UserObj.licenses.value -Headers $Headers
                $Results.Add($LicenseResults)
            }
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to assign the license. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to assign the license. $($_.Exception.Message)")
    }

    try {
        if ($UserObj.AddedAliases) {
            $AliasResults = Add-CIPPAlias -user $CreationResults.Username -Aliases ($UserObj.AddedAliases -split '\s') -UserprincipalName $CreationResults.Username -TenantFilter $UserObj.tenantFilter -APIName $APIName -Headers $Headers
            $Results.Add($AliasResults)
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to create the Aliases. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to create the Aliases: $($_.Exception.Message)")
    }
    if ($UserObj.copyFrom.value) {
        Write-Host "Copying from $($UserObj.copyFrom.value)"
        $CopyFrom = Set-CIPPCopyGroupMembers -Headers $Headers -CopyFromId $UserObj.copyFrom.value -UserID $CreationResults.Username -TenantFilter $UserObj.tenantFilter
        $CopyFrom.Success | ForEach-Object { $Results.Add($_) }
        $CopyFrom.Error | ForEach-Object { $Results.Add($_) }
    }

    if ($UserObj.AddToGroups) {
        $UserObj.AddToGroups | ForEach-Object {
            $GroupType = $_.addedFields.calculatedGroupType
            $GroupID = $_.value
            $GroupName = $_.label
            Write-Host "About to add $($CreationResults.Username) to $GroupName. Group ID is: $GroupID and type is: $GroupType"

            try {
                if ($GroupType -eq 'Distribution List' -or $GroupType -eq 'Mail-Enabled Security') {
                    Write-Host 'Adding to group via Add-DistributionGroupMember'
                    $Params = @{ Identity = $GroupID; Member = $CreationResults.Username; BypassSecurityGroupManagerCheck = $true }
                    $null = New-ExoRequest -tenantid $UserObj.tenantFilter -cmdlet 'Add-DistributionGroupMember' -cmdParams $params -UseSystemMailbox $true
                } else {
                    Write-Host 'Adding to group via Graph'
                    $UserBody = [PSCustomObject]@{
                        '@odata.id' = "https://graph.microsoft.com/beta/directoryObjects/$($CreationResults.UserId)"
                    }
                    $UserBodyJSON = ConvertTo-Json -Compress -Depth 10 -InputObject $UserBody
                    $null = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/groups/$GroupID/members/`$ref" -tenantid $UserObj.tenantFilter -type POST -body $UserBodyJSON -Verbose
                }
                Write-LogMessage -headers $Headers -API $APIName -tenant $UserObj.tenantFilter -message "Added $($CreationResults.Username) to $GroupName group" -Sev 'Info'
                $Results.Add("Success. User has been added to $GroupName")
            } catch {
                $ErrorMessage = Get-CippException -Exception $_
                $Message = "Failed to add user to $GroupName. Error: $($ErrorMessage.NormalizedError)"
                Write-LogMessage -headers $Headers -API $APIName -tenant $UserObj.tenantFilter -message $Message -Sev 'Error' -LogData $ErrorMessage
                $Results.Add($Message)
            }
        }
    }

    if ($UserObj.setManager) {
        $ManagerResult = Set-CIPPManager -user $CreationResults.Username -Manager $UserObj.setManager.value -TenantFilter $UserObj.tenantFilter -APIName 'Set Manager' -Headers $Headers
        $Results.Add($ManagerResult)
    }

    if ($UserObj.setSponsor) {
        $SponsorResult = Set-CIPPManager -user $CreationResults.Username -Manager $UserObj.setSponsor.value -TenantFilter $UserObj.tenantFilter -APIName 'Set Sponsor' -Headers $Headers
        $Results.Add($SponsorResult)
    }

    return @{
        Results  = $Results
        Username = $CreationResults.Username
        Password = $CreationResults.Password
        CopyFrom = $CopyFrom
    }
}
