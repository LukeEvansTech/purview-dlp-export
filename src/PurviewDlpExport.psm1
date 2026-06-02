Set-StrictMode -Version Latest

$script:VolatileFields = @(
    'RunspaceId',
    'ETag',
    'WhenCreatedUTC',
    'WhenChangedUTC',
    'ObjectVersion',
    'ImmutableId'
)

function Compress-EnumCollision {
    # Flattens Purview enum-collision pairs ({ "value": N, "Value": "X" }) in serialised JSON to
    # just the string label "X". JSON-string regex is used instead of a recursive object walk
    # because real Purview objects can blow PowerShell's call-stack on deep traversal.
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $Normalised)

    $json = $Normalised | ConvertTo-Json -Depth 20

    $pattern1 = '\{\s*"value":\s*-?\d+,\s*"Value":\s*("(?:[^"\\]|\\.)*")\s*\}'
    $pattern2 = '\{\s*"Value":\s*("(?:[^"\\]|\\.)*"),\s*"value":\s*-?\d+\s*\}'
    $json = [regex]::Replace($json, $pattern1, '$1')
    $json = [regex]::Replace($json, $pattern2, '$1')

    $json | ConvertFrom-Json
}

function ConvertTo-OrderedTree {
    # PS 5.1-safe replacement for the PS 6+ AsHashtable switch on ConvertFrom-Json:
    # deep-converts a PSCustomObject/array tree into [ordered] dictionaries + arrays.
    # Recursion depth is bounded by JSON nesting, which is shallow for DLP objects (< ~10 levels).
    # Kept a simple (non-advanced) function on purpose: it returns heterogeneous types
    # (ordered dictionary, array, or scalar passthrough), which an [OutputType] can't capture.
    param($Node)

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) {
            $o[$p.Name] = ConvertTo-OrderedTree -Node $p.Value
        }
        return $o
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $arr = @()
        foreach ($item in $Node) { $arr += ,(ConvertTo-OrderedTree -Node $item) }
        return ,$arr
    }
    else {
        return $Node
    }
}

function Format-NormalisedKey {
    # Deep alphabetical sort of all object keys in a normalised inventory. Without this, nested
    # Purview objects (inside EndpointDlpExtendedLocations etc.) keep whatever key order the cmdlet
    # produces, which varies between calls and breaks byte-stability. Uses an iterative DFS with
    # an explicit stack — recursion would overflow on deep Purview structures.
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $Normalised)

    # PS 5.1 lacks the AsHashtable switch on ConvertFrom-Json, so build an ordered-dictionary
    # tree manually. [ordered] preserves insertion order in both 5.1 and 7, which the
    # sort below relies on (a plain hashtable would re-randomise on re-serialisation).
    $json = $Normalised | ConvertTo-Json -Depth 20
    $root = ConvertTo-OrderedTree -Node ($json | ConvertFrom-Json)

    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node -is [System.Collections.IDictionary]) {
            $keys = @($node.Keys) | Sort-Object
            $tmp = [ordered]@{}
            foreach ($k in $keys) { $tmp[$k] = $node[$k] }
            $node.Clear()
            foreach ($k in $keys) {
                $node[$k] = $tmp[$k]
                $v = $tmp[$k]
                if ($v -is [System.Collections.IDictionary]) {
                    $stack.Push($v)
                } elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
                    foreach ($item in $v) { $stack.Push($item) }
                }
            }
        }
        elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) { $stack.Push($item) }
        }
    }

    $root | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Expand-AdvancedRuleReference {
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param([Parameter(Mandatory)] $Rule)

    $sits   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $labels = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Purview puts the canonical condition in AdvancedRule even when IsAdvancedRule is false
    # (simple-UI rules are stored as AdvancedRule JSON under the hood). Don't gate on the flag.
    $hasJson = $Rule.PSObject.Properties.Name -contains 'AdvancedRule' -and -not [string]::IsNullOrEmpty($Rule.AdvancedRule)
    if (-not $hasJson) {
        return @{ Sits = @(); Labels = @() }
    }

    try {
        $parsed = $Rule.AdvancedRule | ConvertFrom-Json
    } catch {
        return @{ Sits = @(); Labels = @() }
    }

    if ($null -eq $parsed.Condition -or $null -eq $parsed.Condition.SubConditions) {
        return @{ Sits = @(); Labels = @() }
    }

    foreach ($sub in $parsed.Condition.SubConditions) {
        if ($sub.ConditionName -ne 'ContentContainsSensitiveInformation') { continue }
        if ($null -eq $sub.Value) { continue }

        foreach ($item in $sub.Value) {
            # Check for nested label/SIT shape (has Groups)
            if ($item.PSObject.Properties.Name -contains 'Groups' -and $null -ne $item.Groups) {
                foreach ($group in $item.Groups) {
                    if ($null -eq $group.Labels) { continue }
                    foreach ($ref in $group.Labels) {
                        $id   = $ref.Id
                        $name = $ref.Name
                        if ($ref.Type -eq 'Sensitivity') {
                            $labels.Add([PSCustomObject]@{ Id = $id; Name = $name })
                        } else {
                            $sits.Add([PSCustomObject]@{ Id = $id; Name = $name })
                        }
                    }
                }
            } else {
                # Flat SIT shape
                $id   = if ($item.PSObject.Properties.Name -contains 'id') { $item.id } else { $item.Id }
                $name = if ($item.PSObject.Properties.Name -contains 'name') { $item.name } else { $item.Name }
                if ($id) {
                    $sits.Add([PSCustomObject]@{ Id = $id; Name = $name })
                }
            }
        }
    }

    @{ Sits = $sits.ToArray(); Labels = $labels.ToArray() }
}

function Resolve-AdvancedRuleReference {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] $SitNameById,    # hashtable Id -> Name
        [Parameter(Mandatory)] $LabelNameById   # hashtable Id -> Name
    )

    $hasAdvancedRule = $Rule.PSObject.Properties.Name -contains 'AdvancedRule' -and -not [string]::IsNullOrEmpty($Rule.AdvancedRule)
    if (-not $hasAdvancedRule) { return $Rule }

    $expanded = Expand-AdvancedRuleReference -Rule $Rule

    $copy = [ordered]@{}
    foreach ($name in ($Rule.PSObject.Properties.Name | Sort-Object)) {
        $copy[$name] = $Rule.PSObject.Properties[$name].Value
    }

    if ($expanded.Sits.Count -gt 0) {
        $copy['ContentContainsSensitiveInformation'] = @($expanded.Sits | ForEach-Object {
            [PSCustomObject]@{
                Id   = $_.Id
                Name = if ($SitNameById.ContainsKey($_.Id)) { $SitNameById[$_.Id] } else { $_.Name }
            }
        })
    }
    if ($expanded.Labels.Count -gt 0) {
        $copy['HasSensitiveInformation'] = @($expanded.Labels | ForEach-Object {
            [PSCustomObject]@{
                Id   = $_.Id
                Name = if ($LabelNameById.ContainsKey($_.Id)) { $LabelNameById[$_.Id] } else { $_.Name }
                Type = 'label'
            }
        })
    }

    [PSCustomObject]$copy
}

function Connect-PurviewDlpSession {
    <#
    .SYNOPSIS
        Connects to the Microsoft Purview Security & Compliance PowerShell endpoint.
    .DESCRIPTION
        Wraps Connect-IPPSSession with a clear error if ExchangeOnlineManagement is not installed.
        Interactive authentication only; service principal / certificate auth is not supported in this version.
    .PARAMETER UserPrincipalName
        The UPN of the administrator account to authenticate as. MFA will be prompted.
    #>
    [CmdletBinding()]
    [OutputType([Void])]
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
    <#
    .SYNOPSIS
        Reads the full DLP rule estate from the connected Purview tenant.
    .DESCRIPTION
        Calls Get-DlpCompliancePolicy and Get-DlpComplianceRule, walks each rule's AdvancedRule
        JSON for SIT/label references, and resolves those references to names via
        Get-DlpSensitiveInformationType and Get-Label. Throws if the inventory comes back empty
        (signals an auth-scope problem rather than a truly empty tenant).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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
        # Expand AdvancedRule first — for advanced rules, inline ContentContainsSensitiveInformation
        # has null properties; the real SIT/label refs are inside the AdvancedRule JSON string.
        $expanded = Expand-AdvancedRuleReference -Rule $rule
        foreach ($s in $expanded.Sits)   { if ($s.Id) { [void]$sitIds.Add($s.Id) } }
        foreach ($l in $expanded.Labels) { if ($l.Id) { [void]$labelIds.Add($l.Id) } }

        # Inline walk — still correct for non-advanced rules.
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

function Skip-VolatileField {
    # Pure function — returns a new PSCustomObject without the specified fields.
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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
    [OutputType([PSCustomObject])]
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
    <#
    .SYNOPSIS
        Transforms a raw DLP inventory into a byte-stable, semantics-only baseline.
    .DESCRIPTION
        Strips volatile fields (timestamps, ETags, RunspaceIds), backfills SIT/label names from
        AdvancedRule references, annotates orphan references, flattens Purview enum-collision
        objects, and deep-sorts all object keys alphabetically. The output is suitable for
        diffing across runs — re-running on an unchanged tenant produces a byte-identical body.
    .PARAMETER Inventory
        The raw inventory object returned by Get-DlpInventory.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        $Inventory
    )

    $knownSitIds   = @($Inventory.ReferencedSits   | ForEach-Object { $_.Id })
    $knownLabelIds = @($Inventory.ReferencedLabels | ForEach-Object { $_.Id })

    $sitNameById   = @{}
    foreach ($s in $Inventory.ReferencedSits)   { $sitNameById[$s.Id]   = $s.Name }
    $labelNameById = @{}
    foreach ($l in $Inventory.ReferencedLabels) { $labelNameById[$l.Id] = $l.Name }

    $strippedPolicies = @($Inventory.Policies | ForEach-Object {
        Skip-VolatileField -Record $_ -Fields $script:VolatileFields
    } | Sort-Object Name)

    $strippedRules = @($Inventory.Rules | ForEach-Object {
        $stripped   = Skip-VolatileField -Record $_ -Fields $script:VolatileFields
        $backfilled = Resolve-AdvancedRuleReference -Rule $stripped `
            -SitNameById $sitNameById -LabelNameById $labelNameById
        Add-OrphanAnnotation -Rule $backfilled `
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
    $normalised = Compress-EnumCollision -Normalised $normalised
    $normalised = Format-NormalisedKey -Normalised $normalised

    [PSCustomObject]@{
        Normalised     = $normalised
        StrippedFields = $script:VolatileFields
    }
}

function Export-DlpBaselineJson {
    <#
    .SYNOPSIS
        Writes a normalised baseline to disk as JSON plus a .meta.json audit sidecar.
    .DESCRIPTION
        Produces two files in OutDir: baseline-<DateStamp>-<Tenant>.json (the byte-stable body)
        and baseline-<DateStamp>-<Tenant>.meta.json (extract timestamp, runner UPN, tool version,
        stripped-fields manifest). Both are written as UTF-8 without BOM.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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

function Format-RuleCondition {
    [CmdletBinding()]
    [OutputType([String])]
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

function Format-RuleAction {
    [CmdletBinding()]
    [OutputType([String])]
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
    <#
    .SYNOPSIS
        Writes a human-readable Markdown summary of the normalised baseline.
    .DESCRIPTION
        Produces baseline-<DateStamp>-<Tenant>.md in OutDir with a per-policy and per-rule
        narrative — conditions in plain English (resolved SIT/label names, keyword lists),
        actions (block/notify/incident report), exception clauses. LF line endings throughout
        for cross-OS byte-stability.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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
            [void]$sb.AppendLine("- Conditions: $(Format-RuleCondition -Rule $rule)")
            [void]$sb.AppendLine("- Actions: $(Format-RuleAction -Rule $rule)")
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
    # Force LF line endings — StringBuilder.AppendLine uses Environment.NewLine which is CRLF on
    # Windows, breaking cross-OS byte-stability against the LF-locked snapshot fixture.
    $content = $sb.ToString() -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($mdPath, $content, $utf8NoBom)

    [PSCustomObject]@{ MarkdownPath = $mdPath }
}

Export-ModuleMember -Function `
    Connect-PurviewDlpSession, `
    Get-DlpInventory, `
    ConvertTo-NormalisedBaseline, `
    Export-DlpBaselineJson, `
    Export-DlpBaselineMarkdown
