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

function Format-SingleLine {
    # Collapse embedded CR/LF runs to a single space so free-text (comments, policy-tip
    # custom text) can't split a CSV row or break a Markdown bullet.
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    ([string]$Value) -replace '[\r\n]+', ' '
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

function Get-RuleDetectorDetail {
    # Builds a guarded id -> "(confidence, instances)" lookup from a rule's raw AdvancedRule JSON.
    # Confidence/instance-count live only on the FLAT SIT items ({id, confidencelevel, mincount,
    # maxcount, ...}). Real rules also use a nested { Operator, Groups:[{Labels:[...]}] } shape for
    # sensitivity-label conditions, which has no top-level id and no confidence - those items are
    # skipped, never read for a name. Returns an empty hashtable when there is nothing usable; it is
    # only an enrichment source, never the source of detector names.
    param([Parameter(Mandatory)] $Rule)

    $detailById = @{}
    $hasAdvanced = $Rule.PSObject.Properties.Name -contains 'AdvancedRule' -and `
        -not [string]::IsNullOrEmpty($Rule.AdvancedRule)
    if (-not $hasAdvanced) { return $detailById }

    try { $parsed = $Rule.AdvancedRule | ConvertFrom-Json } catch { return $detailById }
    if ($null -eq $parsed.Condition -or $null -eq $parsed.Condition.SubConditions) { return $detailById }

    foreach ($sub in $parsed.Condition.SubConditions) {
        if ($sub.ConditionName -ne 'ContentContainsSensitiveInformation') { continue }
        if ($null -eq $sub.Value) { continue }
        foreach ($item in $sub.Value) {
            if ($item.PSObject.Properties.Name -notcontains 'id') { continue }  # skip Groups/label items
            $id = $item.id
            if (-not $id) { continue }
            $detailParts = @()
            if ($item.PSObject.Properties.Name -contains 'confidencelevel') {
                $conf = Format-Confidence -Level $item.confidencelevel
                if ($conf) { $detailParts += $conf }
            }
            $min = if ($item.PSObject.Properties.Name -contains 'mincount') { $item.mincount } else { $null }
            $max = if ($item.PSObject.Properties.Name -contains 'maxcount') { $item.maxcount } else { $null }
            $cnt = Format-InstanceCount -Min $min -Max $max
            if ($cnt) { $detailParts += $cnt }
            if ($detailParts.Count -gt 0) { $detailById[$id] = "($($detailParts -join ', '))" }
        }
    }
    $detailById
}

function Get-RuleDetector {
    # Returns structured detector objects for the SIT/label detectors of a rule.
    # Each object: [PSCustomObject]@{ Kind = 'SIT'|'Label'; Name = <display name>; Detail = <"(...)"|''> }
    #
    # Names/kinds come from the normaliser's RESOLVED, Groups-aware inline properties
    # (ContentContainsSensitiveInformation = SITs, HasSensitiveInformation = labels/SITs) - these
    # carry display names and orphan flags and exist for every rule. Confidence + instance-count
    # live only on the raw AdvancedRule's flat SIT items, so we enrich each SIT by id from a guarded
    # lookup. We deliberately do NOT read detector names from the raw AdvancedRule: its value items
    # are heterogeneous (flat SITs vs nested label Groups) and the nested shape has no 'name', which
    # previously threw under StrictMode on real tenants.
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([Parameter(Mandatory)] $Rule)

    $detectors  = New-Object System.Collections.Generic.List[PSCustomObject]
    $detailById = Get-RuleDetectorDetail -Rule $Rule

    if ($Rule.PSObject.Properties.Name -contains 'ContentContainsSensitiveInformation' -and `
        $null -ne $Rule.ContentContainsSensitiveInformation) {
        foreach ($sit in $Rule.ContentContainsSensitiveInformation) {
            $id   = if ($sit.PSObject.Properties.Name -contains 'id') { $sit.id } else { $null }
            $name = $sit.Name
            if (-not $id -and -not $name) { continue }  # skip empty placeholder items
            if (-not $name) { $name = "<orphan id=$id>" }
            $detail = if ($id -and $detailById.ContainsKey($id)) { $detailById[$id] } else { '' }
            $detectors.Add([PSCustomObject]@{ Kind = 'SIT'; Name = $name; Detail = $detail })
        }
    }
    if ($Rule.PSObject.Properties.Name -contains 'HasSensitiveInformation' -and `
        $null -ne $Rule.HasSensitiveInformation) {
        foreach ($ref in $Rule.HasSensitiveInformation) {
            $id   = if ($ref.PSObject.Properties.Name -contains 'id') { $ref.id } else { $null }
            $type = if ($ref.PSObject.Properties.Name -contains 'type') { $ref.type } else { $null }
            $name = $ref.Name
            if (-not $id -and -not $name) { continue }
            $kind = if ($type -eq 'label') { 'Label' } else { 'SIT' }
            if (-not $name) { $name = "<orphan id=$id>" }
            $detail = if ($id -and $detailById.ContainsKey($id)) { $detailById[$id] } else { '' }
            $detectors.Add([PSCustomObject]@{ Kind = $kind; Name = $name; Detail = $detail })
        }
    }
    $detectors.ToArray()
}

function Get-RuleConditionLine {
    # Full condition set: detectors + keywords + file-extension words.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Rule)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-RuleDetector -Rule $Rule)) {
        $line = "$($d.Kind): $($d.Name)"
        if ($d.Detail) { $line += " $($d.Detail)" }
        $lines.Add($line)
    }

    if ($Rule.PSObject.Properties.Name -contains 'ContentMatchesKeywords' -and `
        $null -ne $Rule.ContentMatchesKeywords -and @($Rule.ContentMatchesKeywords).Count -gt 0) {
        $lines.Add("Keywords: $(@($Rule.ContentMatchesKeywords) -join ', ')")
    }
    if ($Rule.PSObject.Properties.Name -contains 'ContentExtensionMatchesWords' -and `
        $null -ne $Rule.ContentExtensionMatchesWords -and @($Rule.ContentExtensionMatchesWords).Count -gt 0) {
        $lines.Add("File extensions: $(@($Rule.ContentExtensionMatchesWords) -join ', ')")
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
    # Endpoint DLP enforcement - one line per { setting, value } restriction (Print=Warn, etc.).
    if ($p -contains 'EndpointDlpRestrictions' -and $Rule.EndpointDlpRestrictions) {
        foreach ($r in @($Rule.EndpointDlpRestrictions)) {
            $setting = if ($r.PSObject.Properties.Name -contains 'setting') { $r.setting } else { $null }
            $value   = if ($r.PSObject.Properties.Name -contains 'value')   { $r.value }   else { $null }
            if ($setting) {
                $line = "Endpoint restriction: $setting"
                if ($value) { $line += " = $value" }
                $a.Add($line)
            }
        }
    }
    if ($p -contains 'NotifyUser' -and $Rule.NotifyUser) {
        $a.Add("Notify: $($Rule.NotifyUser -join ', ')")
    }
    if ($p -contains 'NotifyPolicyTipCustomText' -and $Rule.NotifyPolicyTipCustomText) {
        $a.Add("Policy tip: `"$(Format-SingleLine $Rule.NotifyPolicyTipCustomText)`"")
    }
    # GenerateAlert is either a flag (['true']) or a list of recipient addresses.
    if ($p -contains 'GenerateAlert' -and $Rule.GenerateAlert) {
        $recipients = @($Rule.GenerateAlert | Where-Object {
            $t = "$_"; $t -and $t.ToLower() -ne 'true' -and $t.ToLower() -ne 'false'
        })
        if ($recipients.Count -gt 0) {
            $a.Add("Alert to: $($recipients -join ', ')")
        }
        elseif (@($Rule.GenerateAlert | Where-Object { "$_".ToLower() -eq 'true' }).Count -gt 0) {
            $a.Add('Generate alert')
        }
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

function Get-LocationLabel {
    # Friendly label for one *Location entry. Purview location values are rich objects
    # (@{DisplayName=All; Name=All; ...}); render their DisplayName (else Name), never the raw
    # @{...} dump. A plain string value is returned as-is. Guards access for StrictMode.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    foreach ($k in 'DisplayName', 'Name') {
        if ($Value.PSObject.Properties.Name -contains $k) {
            $label = [string]$Value.$k
            if (-not [string]::IsNullOrWhiteSpace($label)) { return $label }
        }
    }
    [string]$Value
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
            foreach ($v in @($prop.Value)) { $excluded.Add("$($prop.Name): $(Get-LocationLabel -Value $v)") }
        }
        elseif ($prop.Name -like '*Location' -and $prop.Value) {
            foreach ($v in @($prop.Value)) { $included.Add("$($prop.Name): $(Get-LocationLabel -Value $v)") }
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
                $summary = @($detectors | ForEach-Object { $_.Name }) -join ', '
                $ruleMode     = if ($rule.PSObject.Properties.Name -contains 'Mode')     { $rule.Mode }     else { $null }
                $rulePriority = if ($rule.PSObject.Properties.Name -contains 'Priority') { $rule.Priority } else { $null }
                [PSCustomObject]@{
                    Name             = $rule.Name
                    Mode             = Format-Mode -Mode $ruleMode
                    Enabled          = -not ($rule.PSObject.Properties.Name -contains 'Disabled' -and $rule.Disabled)
                    Priority         = $rulePriority
                    Comment          = if ($rule.PSObject.Properties.Name -contains 'Comment') { Format-SingleLine $rule.Comment } else { $null }
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
            Comment   = if ($policy.PSObject.Properties.Name -contains 'Comment') { Format-SingleLine $policy.Comment } else { $null }
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
    $policyCount = @($View.Policies).Count
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
        [void]$sb.AppendLine("| $($p.Name) | $enabledNote | $($p.Workloads) | $(@($p.Rules).Count) | $detects | $acts | $($p.Priority) |")
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-overview.md"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ OverviewPath = $path }
}

function Export-DlpDetailMarkdown {
    <#
    .SYNOPSIS
        Writes the deep-dive tier: per-policy scope + per-rule conditions/actions/exceptions.
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

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Purview DLP Detail - $Tenant")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- Date: $DateStamp")
    [void]$sb.AppendLine()

    foreach ($p in $View.Policies) {
        [void]$sb.AppendLine("## Policy: $($p.Name)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("- Mode: $($p.Mode)")
        [void]$sb.AppendLine("- Enabled: $($p.Enabled)")
        [void]$sb.AppendLine("- Priority: $($p.Priority)")
        [void]$sb.AppendLine("- Applies to: $($p.Workloads)")
        if (@($p.Scope.Included).Count -gt 0) {
            [void]$sb.AppendLine("- Included locations:")
            foreach ($i in @($p.Scope.Included)) { [void]$sb.AppendLine("  - $i") }
        }
        if (@($p.Scope.Excluded).Count -gt 0) {
            [void]$sb.AppendLine("- Excluded locations:")
            foreach ($x in @($p.Scope.Excluded)) { [void]$sb.AppendLine("  - $x") }
        }
        if ($p.Comment) { [void]$sb.AppendLine("- Comment: $($p.Comment)") }
        [void]$sb.AppendLine()

        foreach ($r in $p.Rules) {
            [void]$sb.AppendLine("### Rule: $($r.Name)")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("- Mode: $($r.Mode)")
            [void]$sb.AppendLine("- Enabled: $($r.Enabled)")
            [void]$sb.AppendLine("- Priority: $($r.Priority)")
            $detectsLine = if ([string]::IsNullOrWhiteSpace($r.DetectionSummary)) { '(no sensitive-info type; see conditions)' } else { $r.DetectionSummary }
            [void]$sb.AppendLine("- Detects: $detectsLine")
            [void]$sb.AppendLine("- Conditions:")
            foreach ($c in @($r.Conditions)) { [void]$sb.AppendLine("  - $c") }
            [void]$sb.AppendLine("- Actions:")
            foreach ($a in @($r.Actions)) { [void]$sb.AppendLine("  - $a") }
            if (@($r.Exceptions).Count -gt 0) {
                [void]$sb.AppendLine("- Exceptions:")
                foreach ($e in @($r.Exceptions)) { [void]$sb.AppendLine("  - $e") }
            }
            if ($r.Comment) { [void]$sb.AppendLine("- Comment: $($r.Comment)") }
            [void]$sb.AppendLine()
        }
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-detail.md"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ DetailPath = $path }
}

function ConvertTo-CsvField {
    # RFC-4180 quoting: wrap in quotes, double any embedded quotes. Always quote so
    # commas/semicolons inside multi-value cells never split a row.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    '"' + ($s -replace '"', '""') + '"'
}

function Export-DlpMatrixCsv {
    <#
    .SYNOPSIS
        Writes the analysis tier: one row per rule for sorting/filtering in Excel.
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

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("Policy,Rule,Workloads,Enabled,Mode,Priority,Detects,Conditions,Actions,Exceptions`n")

    foreach ($p in $View.Policies) {
        foreach ($r in $p.Rules) {
            $row = @(
                (ConvertTo-CsvField $p.Name),
                (ConvertTo-CsvField $r.Name),
                (ConvertTo-CsvField $p.Workloads),
                (ConvertTo-CsvField $r.Enabled),
                (ConvertTo-CsvField $r.Mode),
                (ConvertTo-CsvField $r.Priority),
                (ConvertTo-CsvField $r.DetectionSummary),
                (ConvertTo-CsvField (@($r.Conditions) -join '; ')),
                (ConvertTo-CsvField (@($r.Actions) -join '; ')),
                (ConvertTo-CsvField (@($r.Exceptions) -join '; '))
            ) -join ','
            [void]$sb.Append("$row`n")
        }
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-matrix.csv"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ MatrixPath = $path }
}

Export-ModuleMember -Function ConvertTo-DlpView, Export-DlpOverviewMarkdown, Export-DlpDetailMarkdown, Export-DlpMatrixCsv
