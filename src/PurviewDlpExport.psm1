Set-StrictMode -Version Latest

$script:VolatileFields = @(
    'RunspaceId',
    'ETag',
    'WhenCreatedUTC',
    'WhenChangedUTC',
    'ObjectVersion',
    'ImmutableId'
)

function Connect-PurviewDlpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName
    )

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw "ExchangeOnlineManagement module not installed. Run: Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser"
    }

    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    Connect-IPPSSession -UserPrincipalName $UserPrincipalName -ErrorAction Stop
}

function Get-DlpInventory {
    [CmdletBinding()]
    param()

    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop)
    $rules    = @(Get-DlpComplianceRule   -ErrorAction Stop)

    if ($policies.Count -eq 0) {
        throw "0 policies returned — check your account has Compliance Administrator or DLP Reader role on this tenant."
    }
    if ($rules.Count -eq 0) {
        throw "0 rules returned — policies exist but no rules. Verify account permissions."
    }

    $sitIds   = New-Object System.Collections.Generic.HashSet[string]
    $labelIds = New-Object System.Collections.Generic.HashSet[string]

    foreach ($rule in $rules) {
        if ($rule.PSObject.Properties.Name -contains 'ContentContainsSensitiveInformation' `
            -and $null -ne $rule.ContentContainsSensitiveInformation) {
            foreach ($s in $rule.ContentContainsSensitiveInformation) {
                if ($s.id) { [void]$sitIds.Add($s.id) }
            }
        }
        if ($rule.PSObject.Properties.Name -contains 'HasSensitiveInformation' `
            -and $null -ne $rule.HasSensitiveInformation) {
            foreach ($ref in $rule.HasSensitiveInformation) {
                if ($ref.type -eq 'label') {
                    if ($ref.id) { [void]$labelIds.Add($ref.id) }
                } else {
                    if ($ref.id) { [void]$sitIds.Add($ref.id) }
                }
            }
        }
    }

    $referencedSits = @()
    foreach ($id in $sitIds) {
        try {
            $sit = Get-DlpSensitiveInformationType -Identity $id -ErrorAction Stop
            $referencedSits += [PSCustomObject]@{ Id = $id; Name = $sit.Name }
        } catch {
            $referencedSits += [PSCustomObject]@{ Id = $id; Name = $null }
        }
    }

    $referencedLabels = @()
    foreach ($id in $labelIds) {
        try {
            $label = Get-Label -Identity $id -ErrorAction Stop
            $referencedLabels += [PSCustomObject]@{ Id = $id; Name = $label.DisplayName }
        } catch {
            $referencedLabels += [PSCustomObject]@{ Id = $id; Name = $null }
        }
    }

    [PSCustomObject]@{
        Policies         = $policies
        Rules            = $rules
        ReferencedSits   = $referencedSits
        ReferencedLabels = $referencedLabels
    }
}

function Remove-VolatileFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record,
        [Parameter(Mandatory)]
        [string[]] $Fields
    )

    $copy = [ordered]@{}
    $sortedNames = $Record.PSObject.Properties.Name | Sort-Object
    foreach ($name in $sortedNames) {
        if ($Fields -notcontains $name) {
            $copy[$name] = $Record.PSObject.Properties[$name].Value
        }
    }
    [PSCustomObject]$copy
}

function Add-OrphanAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Rule,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $KnownSitIds,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $KnownLabelIds
    )

    $copy = [ordered]@{}
    foreach ($name in ($Rule.PSObject.Properties.Name | Sort-Object)) {
        $value = $Rule.PSObject.Properties[$name].Value

        if ($name -eq 'ContentContainsSensitiveInformation' -and $null -ne $value) {
            $value = @($value | ForEach-Object {
                $raw = [ordered]@{}
                foreach ($p in ($_.PSObject.Properties.Name | Sort-Object)) {
                    $raw[$p] = $_.PSObject.Properties[$p].Value
                }
                $raw['Orphan'] = ($KnownSitIds -notcontains $_.id)
                $ref = [ordered]@{}
                foreach ($k in ($raw.Keys | Sort-Object)) { $ref[$k] = $raw[$k] }
                [PSCustomObject]$ref
            })
        }
        elseif ($name -eq 'HasSensitiveInformation' -and $null -ne $value) {
            $value = @($value | ForEach-Object {
                $raw = [ordered]@{}
                foreach ($p in ($_.PSObject.Properties.Name | Sort-Object)) {
                    $raw[$p] = $_.PSObject.Properties[$p].Value
                }
                if ($_.type -eq 'label') {
                    $raw['Orphan'] = ($KnownLabelIds -notcontains $_.id)
                } else {
                    $raw['Orphan'] = ($KnownSitIds -notcontains $_.id)
                }
                $ref = [ordered]@{}
                foreach ($k in ($raw.Keys | Sort-Object)) { $ref[$k] = $raw[$k] }
                [PSCustomObject]$ref
            })
        }

        $copy[$name] = $value
    }
    [PSCustomObject]$copy
}

function ConvertTo-NormalisedBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Inventory
    )

    $knownSitIds   = @($Inventory.ReferencedSits   | ForEach-Object { $_.Id })
    $knownLabelIds = @($Inventory.ReferencedLabels | ForEach-Object { $_.Id })

    $strippedPolicies = @($Inventory.Policies | ForEach-Object {
        Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
    } | Sort-Object Name)

    $strippedRules = @($Inventory.Rules | ForEach-Object {
        $stripped = Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
        Add-OrphanAnnotation -Rule $stripped `
            -KnownSitIds $knownSitIds `
            -KnownLabelIds $knownLabelIds
    } | Sort-Object ParentPolicyName, Name)

    $sortedSits   = @($Inventory.ReferencedSits   | Sort-Object Name)
    $sortedLabels = @($Inventory.ReferencedLabels | Sort-Object Name)

    $normalised = [PSCustomObject]@{
        Policies         = $strippedPolicies
        Rules            = $strippedRules
        ReferencedSits   = $sortedSits
        ReferencedLabels = $sortedLabels
    }

    [PSCustomObject]@{
        Normalised     = $normalised
        StrippedFields = $script:VolatileFields
    }
}

function Export-DlpBaselineJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Normalised,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [string] $Tenant,
        [Parameter(Mandatory)] [string[]] $StrippedFields,
        [Parameter(Mandatory)] [string] $DateStamp,
        [Parameter(Mandatory)] [string] $RunnerUpn
    )

    if (-not (Test-Path $OutDir)) {
        throw "OutDir does not exist: $OutDir"
    }

    $jsonPath = Join-Path $OutDir "baseline-$DateStamp-$Tenant.json"
    $metaPath = Join-Path $OutDir "baseline-$DateStamp-$Tenant.meta.json"

    $jsonBody = $Normalised | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, $jsonBody, $utf8NoBom)

    $meta = [PSCustomObject]@{
        Tenant              = $Tenant
        RunnerUpn           = $RunnerUpn
        ExtractTimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        StrippedFields      = $StrippedFields
        ToolVersion         = (Get-Module PurviewDlpExport).Version.ToString()
    }
    $metaBody = $meta | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($metaPath, $metaBody, $utf8NoBom)

    [PSCustomObject]@{
        JsonPath = $jsonPath
        MetaPath = $metaPath
    }
}

function Format-RuleConditions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Rule)

    $parts = @()

    if ($Rule.PSObject.Properties.Name -contains 'ContentContainsSensitiveInformation' `
        -and $null -ne $Rule.ContentContainsSensitiveInformation) {
        foreach ($sit in $Rule.ContentContainsSensitiveInformation) {
            $name = if ($sit.name) { $sit.name } else { "<orphan id=$($sit.id)>" }
            $parts += "SIT *$name*"
        }
    }

    if ($Rule.PSObject.Properties.Name -contains 'HasSensitiveInformation' `
        -and $null -ne $Rule.HasSensitiveInformation) {
        foreach ($ref in $Rule.HasSensitiveInformation) {
            $kind = if ($ref.type -eq 'label') { 'label' } else { 'SIT' }
            $name = if ($ref.name) { $ref.name } else { "<orphan id=$($ref.id)>" }
            $parts += "$kind *$name*"
        }
    }

    if ($Rule.PSObject.Properties.Name -contains 'ContentMatchesKeywords' `
        -and $null -ne $Rule.ContentMatchesKeywords) {
        $kw = ($Rule.ContentMatchesKeywords -join ', ')
        $parts += "keywords: $kw"
    }

    if ($parts.Count -eq 0) { '(no conditions)' } else { $parts -join ' OR ' }
}

function Format-RuleActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Rule)

    $actions = @()
    if ($Rule.PSObject.Properties.Name -contains 'BlockAccess' -and $Rule.BlockAccess) {
        $actions += 'block'
    }
    if ($Rule.PSObject.Properties.Name -contains 'NotifyUser' -and $Rule.NotifyUser) {
        $actions += "notify: $($Rule.NotifyUser -join ', ')"
    }
    if ($Rule.PSObject.Properties.Name -contains 'GenerateIncidentReport' -and $Rule.GenerateIncidentReport) {
        $actions += "incident report: $($Rule.GenerateIncidentReport -join ', ')"
    }
    if ($actions.Count -eq 0) { '(no actions)' } else { $actions -join '; ' }
}

function Export-DlpBaselineMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Normalised,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [string] $Tenant,
        [Parameter(Mandatory)] [string] $DateStamp
    )

    if (-not (Test-Path $OutDir)) {
        throw "OutDir does not exist: $OutDir"
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Purview DLP Baseline — $Tenant")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- Date: $DateStamp")
    [void]$sb.AppendLine("- Policies: $($Normalised.Policies.Count)")
    [void]$sb.AppendLine("- Rules: $($Normalised.Rules.Count)")
    [void]$sb.AppendLine()

    foreach ($policy in $Normalised.Policies) {
        [void]$sb.AppendLine("## Policy: $($policy.Name)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("- Mode: $($policy.Mode)")
        [void]$sb.AppendLine("- Enabled: $($policy.Enabled)")
        [void]$sb.AppendLine("- Workload: $($policy.Workload)")
        [void]$sb.AppendLine("- Priority: $($policy.Priority)")
        if ($policy.PSObject.Properties.Name -contains 'Comment' -and $policy.Comment) {
            [void]$sb.AppendLine("- Comment: $($policy.Comment)")
        }
        [void]$sb.AppendLine()

        $childRules = $Normalised.Rules | Where-Object { $_.ParentPolicyName -eq $policy.Name }
        foreach ($rule in $childRules) {
            [void]$sb.AppendLine("### Rule: $($rule.Name)")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("- Mode: $($rule.Mode)")
            [void]$sb.AppendLine("- Priority: $($rule.Priority)")
            [void]$sb.AppendLine("- Disabled: $($rule.Disabled)")
            [void]$sb.AppendLine("- Conditions: $(Format-RuleConditions -Rule $rule)")
            [void]$sb.AppendLine("- Actions: $(Format-RuleActions -Rule $rule)")
            if ($rule.PSObject.Properties.Name -contains 'ExceptIfRecipientDomainIs' -and $rule.ExceptIfRecipientDomainIs) {
                [void]$sb.AppendLine("- Except if recipient domain in: $($rule.ExceptIfRecipientDomainIs -join ', ')")
            }
            if ($rule.PSObject.Properties.Name -contains 'Comment' -and $rule.Comment) {
                [void]$sb.AppendLine("- Comment: $($rule.Comment)")
            }
            [void]$sb.AppendLine()
        }
    }

    $mdPath = Join-Path $OutDir "baseline-$DateStamp-$Tenant.md"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($mdPath, $sb.ToString(), $utf8NoBom)

    [PSCustomObject]@{ MarkdownPath = $mdPath }
}

Export-ModuleMember -Function `
    Connect-PurviewDlpSession, `
    Get-DlpInventory, `
    ConvertTo-NormalisedBaseline, `
    Export-DlpBaselineJson, `
    Export-DlpBaselineMarkdown
