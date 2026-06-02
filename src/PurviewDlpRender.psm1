Set-StrictMode -Version 3.0

function Format-Workload {
    # "Exchange,SharePoint,OneDriveForBusiness" -> "Exchange, SharePoint, OneDrive"
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Workload)

    $map = @{
        'Exchange'             = 'Exchange'
        'SharePoint'           = 'SharePoint'
        'OneDriveForBusiness'  = 'OneDrive'
        'Teams'                = 'Teams'
        'EndpointDevices'      = 'Endpoint'
        'OnPremisesScanner'    = 'On-prem scanner'
    }
    if ([string]::IsNullOrWhiteSpace($Workload)) { return '(none)' }
    $parts = $Workload -split ',' | ForEach-Object {
        $t = $_.Trim()
        if ($map.ContainsKey($t)) { $map[$t] } else { $t }
    }
    $parts -join ', '
}

function Format-Mode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Mode)
    switch ($Mode) {
        'Enable'                   { 'Enforce'; break }
        'TestWithNotifications'    { 'Test (notify)'; break }
        'TestWithoutNotifications' { 'Test (silent)'; break }
        'Disable'                  { 'Disabled'; break }
        default                    { if ($Mode) { $Mode } else { '(unknown)' } }
    }
}

function Format-InstanceCount {
    # min "10", max "-1" -> "10+ instances"; min "1" max "50" -> "1-50 instances"
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Min, [AllowNull()] $Max)
    if ($null -eq $Min) { return $null }
    $minN = [int]$Min
    if ($null -eq $Max -or [int]$Max -lt 0) { return "$minN+ instances" }
    "$minN-$([int]$Max) instances"
}

function Format-Confidence {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Level)
    if ([string]::IsNullOrWhiteSpace($Level)) { return $null }
    "$($Level.ToString().ToLower()) confidence"
}

function Get-RuleDetector {
    # Returns plain-English condition lines for the SIT/label detectors of a rule.
    # Prefers the AdvancedRule JSON (carries confidence + counts); falls back to the
    # normaliser's resolved ContentContainsSensitiveInformation / HasSensitiveInformation.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Rule)

    $lines = New-Object System.Collections.Generic.List[string]
    $hasAdvanced = $Rule.PSObject.Properties.Name -contains 'AdvancedRule' -and `
        -not [string]::IsNullOrEmpty($Rule.AdvancedRule)

    if ($hasAdvanced) {
        try { $parsed = $Rule.AdvancedRule | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -ne $parsed -and $null -ne $parsed.Condition -and `
            $null -ne $parsed.Condition.SubConditions) {
            foreach ($sub in $parsed.Condition.SubConditions) {
                if ($sub.ConditionName -ne 'ContentContainsSensitiveInformation') { continue }
                foreach ($item in $sub.Value) {
                    $name = if ($item.name) { $item.name } else { "<orphan id=$($item.id)>" }
                    $detail = @()
                    $conf = Format-Confidence -Level $item.confidencelevel
                    if ($conf) { $detail += $conf }
                    $cnt = Format-InstanceCount -Min $item.mincount -Max $item.maxcount
                    if ($cnt) { $detail += $cnt }
                    $line = "SIT: $name"
                    if ($detail.Count -gt 0) { $line += " ($($detail -join ', '))" }
                    $lines.Add($line)
                }
            }
            if ($lines.Count -gt 0) { return $lines.ToArray() }
        }
    }

    if ($Rule.PSObject.Properties.Name -contains 'ContentContainsSensitiveInformation' -and `
        $null -ne $Rule.ContentContainsSensitiveInformation) {
        foreach ($sit in $Rule.ContentContainsSensitiveInformation) {
            $name = if ($sit.Name) { $sit.Name } elseif ($sit.name) { $sit.name } else { "<orphan id=$($sit.id)>" }
            $lines.Add("SIT: $name")
        }
    }
    if ($Rule.PSObject.Properties.Name -contains 'HasSensitiveInformation' -and `
        $null -ne $Rule.HasSensitiveInformation) {
        foreach ($ref in $Rule.HasSensitiveInformation) {
            $kind = if ($ref.Type -eq 'label' -or $ref.type -eq 'label') { 'Label' } else { 'SIT' }
            $name = if ($ref.Name) { $ref.Name } elseif ($ref.name) { $ref.name } else { "<orphan id=$($ref.id)>" }
            $lines.Add("${kind}: $name")
        }
    }
    $lines.ToArray()
}

function Get-RuleConditionLine {
    # Full condition set: detectors + keywords + file-extension words.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Rule)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-RuleDetector -Rule $Rule)) { $lines.Add($d) }

    if ($Rule.PSObject.Properties.Name -contains 'ContentMatchesKeywords' -and `
        $null -ne $Rule.ContentMatchesKeywords) {
        $lines.Add("Keywords: $($Rule.ContentMatchesKeywords -join ', ')")
    }
    if ($Rule.PSObject.Properties.Name -contains 'ContentExtensionMatchesWords' -and `
        $null -ne $Rule.ContentExtensionMatchesWords) {
        $lines.Add("File extensions: $($Rule.ContentExtensionMatchesWords -join ', ')")
    }
    if ($lines.Count -eq 0) { $lines.Add('(no conditions)') }
    $lines.ToArray()
}

function Get-RuleActionLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Rule)

    $a = New-Object System.Collections.Generic.List[string]
    $p = $Rule.PSObject.Properties.Name

    if ($p -contains 'BlockAccess' -and $Rule.BlockAccess) {
        $scope = if ($p -contains 'BlockAccessScope') { $Rule.BlockAccessScope } else { $null }
        switch ($scope) {
            'All'               { $a.Add('Block access for everyone'); break }
            'PerUser'           { $a.Add('Block access for external/guest recipients'); break }
            'PerAnonymousUser'  { $a.Add('Block access for anonymous recipients'); break }
            default             { $a.Add('Block access') }
        }
    }
    if ($p -contains 'Encrypt' -and $Rule.Encrypt) { $a.Add('Encrypt (RMS)') }
    if ($p -contains 'NotifyUser' -and $Rule.NotifyUser) {
        $a.Add("Notify: $($Rule.NotifyUser -join ', ')")
    }
    if ($p -contains 'NotifyPolicyTipCustomText' -and $Rule.NotifyPolicyTipCustomText) {
        $a.Add("Policy tip: `"$($Rule.NotifyPolicyTipCustomText)`"")
    }
    if ($p -contains 'GenerateIncidentReport' -and $Rule.GenerateIncidentReport) {
        $a.Add("Incident report to: $($Rule.GenerateIncidentReport -join ', ')")
    }
    if ($a.Count -eq 0) { $a.Add('(no actions)') }
    $a.ToArray()
}

function Get-RuleExceptionLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Rule)

    $e = New-Object System.Collections.Generic.List[string]
    $p = $Rule.PSObject.Properties.Name
    if ($p -contains 'ExceptIfRecipientDomainIs' -and $Rule.ExceptIfRecipientDomainIs) {
        $e.Add("Recipient domain in: $($Rule.ExceptIfRecipientDomainIs -join ', ')")
    }
    if ($p -contains 'ExceptIfFrom' -and $Rule.ExceptIfFrom) {
        $e.Add("Sender is: $($Rule.ExceptIfFrom -join ', ')")
    }
    $e.ToArray()
}

function Get-PolicyScope {
    # Returns @{ Included = [..]; Excluded = [..] } from any *Location/*LocationException
    # arrays present on the policy. Empty when the policy only carries the Workload string.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $Policy)

    $included = New-Object System.Collections.Generic.List[string]
    $excluded = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $Policy.PSObject.Properties) {
        if ($prop.Name -like '*LocationException' -and $prop.Value) {
            foreach ($v in $prop.Value) { $excluded.Add("$($prop.Name): $v") }
        }
        elseif ($prop.Name -like '*Location' -and $prop.Value) {
            foreach ($v in $prop.Value) { $included.Add("$($prop.Name): $v") }
        }
    }
    @{ Included = $included.ToArray(); Excluded = $excluded.ToArray() }
}

function ConvertTo-DlpView {
    <#
    .SYNOPSIS
        Builds a resolved, human-readable presentation model from a normalised baseline.
    .DESCRIPTION
        Pure transform. Each policy gets friendly workloads, mode, and scope; each rule gets
        a one-line DetectionSummary plus plain-English Conditions, Actions, and Exceptions.
        Shared by the overview/detail/CSV emitters so all three agree.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $Normalised)

    $policies = @($Normalised.Policies | Sort-Object Priority, Name | ForEach-Object {
        $policy = $_
        $childRules = @($Normalised.Rules |
            Where-Object { $_.ParentPolicyName -eq $policy.Name } |
            Sort-Object Priority, Name | ForEach-Object {
                $rule = $_
                $detectors = Get-RuleDetector -Rule $rule
                $summary = @($detectors | ForEach-Object {
                    # strip the "SIT: "/"Label: " prefix, then strip only the appended
                    # detail suffix "(…confidence, …instances)" — non-nested single group
                    # so acronym parens in detector names (e.g. "(SSN)") are preserved.
                    ($_ -replace '^(SIT|Label):\s*', '') -replace '\s*\([^()]*\)$', ''
                }) -join ', '
                $ruleMode     = if ($rule.PSObject.Properties.Name -contains 'Mode')     { $rule.Mode }     else { $null }
                $rulePriority = if ($rule.PSObject.Properties.Name -contains 'Priority') { $rule.Priority } else { $null }
                [PSCustomObject]@{
                    Name             = $rule.Name
                    Mode             = Format-Mode -Mode $ruleMode
                    Enabled          = -not ($rule.PSObject.Properties.Name -contains 'Disabled' -and $rule.Disabled)
                    Priority         = $rulePriority
                    Comment          = if ($rule.PSObject.Properties.Name -contains 'Comment') { $rule.Comment } else { $null }
                    DetectionSummary = $summary
                    Conditions       = Get-RuleConditionLine -Rule $rule
                    Actions          = Get-RuleActionLine -Rule $rule
                    Exceptions       = Get-RuleExceptionLine -Rule $rule
                }
            })

        $scope          = Get-PolicyScope -Policy $policy
        $policyEnabled  = if ($policy.PSObject.Properties.Name -contains 'Enabled')   { [bool]$policy.Enabled }           else { $true }
        $policyWorkload = if ($policy.PSObject.Properties.Name -contains 'Workload')  { [string]$policy.Workload }        else { '' }
        $policyPriority = if ($policy.PSObject.Properties.Name -contains 'Priority')  { $policy.Priority }                else { $null }
        $policyMode     = if ($policy.PSObject.Properties.Name -contains 'Mode')      { $policy.Mode }                    else { $null }
        [PSCustomObject]@{
            Name      = $policy.Name
            Mode      = Format-Mode -Mode $policyMode
            Enabled   = $policyEnabled
            Priority  = $policyPriority
            Comment   = if ($policy.PSObject.Properties.Name -contains 'Comment') { $policy.Comment } else { $null }
            Workloads = Format-Workload -Workload $policyWorkload
            Scope     = $scope
            Rules     = $childRules
        }
    })

    [PSCustomObject]@{ Policies = $policies }
}

function Write-NoBomLf {
    # Shared writer: UTF-8 no BOM, LF endings.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lf = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $lf, $utf8NoBom)
}

function Export-DlpOverviewMarkdown {
    <#
    .SYNOPSIS
        Writes the scan-tier overview: header counts + one table row per policy.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $View,
        [Parameter(Mandatory)][string] $OutDir,
        [Parameter(Mandatory)][string] $Tenant,
        [Parameter(Mandatory)][string] $DateStamp
    )
    if (-not (Test-Path $OutDir)) { throw "OutDir does not exist: $OutDir" }

    $allRules    = @($View.Policies | ForEach-Object { $_.Rules })
    $policyCount = $View.Policies.Count
    $ruleCount   = $allRules.Count
    $enforceCount = @($View.Policies | Where-Object { $_.Mode -eq 'Enforce' }).Count
    $testCount    = @($View.Policies | Where-Object { $_.Mode -like 'Test*' }).Count
    $disabledRules = @($allRules | Where-Object { -not $_.Enabled }).Count

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Purview DLP Overview - $Tenant")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- Date: $DateStamp")
    [void]$sb.AppendLine("- Policies: $policyCount ($enforceCount enforce, $testCount test)")
    [void]$sb.AppendLine("- Rules: $ruleCount ($disabledRules disabled)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Policy | Mode | Workloads | Rules | Detects | Acts | Priority |")
    [void]$sb.AppendLine("| --- | --- | --- | --- | --- | --- | --- |")

    foreach ($p in $View.Policies) {
        $detects = @($p.Rules | ForEach-Object { $_.DetectionSummary } |
            Where-Object { $_ } | Select-Object -Unique) -join '; '
        if (-not $detects) { $detects = '-' }
        $acts = @($p.Rules | ForEach-Object { $_.Actions } |
            ForEach-Object { ($_ -split ':')[0].Trim() } | Select-Object -Unique) -join '; '
        if (-not $acts) { $acts = '-' }
        $enabledNote = if ($p.Enabled) { $p.Mode } else { "$($p.Mode) (off)" }
        [void]$sb.AppendLine("| $($p.Name) | $enabledNote | $($p.Workloads) | $($p.Rules.Count) | $detects | $acts | $($p.Priority) |")
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-overview.md"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ OverviewPath = $path }
}

Export-ModuleMember -Function ConvertTo-DlpView, Export-DlpOverviewMarkdown
