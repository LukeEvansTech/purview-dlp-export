# PS 5.1 Support + Human-Readable Layered Output — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the exporter run on Windows PowerShell 5.1 and emit three layered, human-readable outputs (overview Markdown, detail Markdown, CSV matrix) computed from a single shared view model.

**Architecture:** The tenant-touching fetch and the byte-stable JSON normaliser are unchanged. A new pure stage `ConvertTo-DlpView` turns the normalised baseline into a fully-resolved presentation model; three thin emitters render it. All presentation lives in a new module `src/PurviewDlpRender.psm1`. The one PS 6+ construct (`ConvertFrom-Json -AsHashtable`) is replaced with a 5.1-safe deep-sort.

**Tech Stack:** PowerShell 5.1-compatible (`.psm1`/`.psd1`), Pester 5, PSScriptAnalyzer (via super-linter). Tests run on PS 7; runtime target is PS 5.1.

**Spec:** `docs/superpowers/specs/2026-06-02-ps51-and-readable-output-design.md`

**Conventions carried from the codebase:**
- All text files written with `[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))` (UTF-8 no BOM).
- Markdown/CSV force LF: `$content = $sb.ToString() -replace "`r`n", "`n"`.
- `ConvertTo-Json`/`ConvertFrom-Json` always use `-Depth 20` where applicable.
- Tests import the module via the manifest: `Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force`.

---

## Task 1: PowerShell 5.1 compatibility

**Files:**
- Modify: `src/PurviewDlpExport.psm1` (`Format-NormalisedKey`, lines 30-67)
- Modify: `scripts/Export-PurviewDlp.ps1:1` and `:13-16`
- Modify: `src/PurviewDlpExport.psd1:7`
- Modify: `.github/linters/.powershell-psscriptanalyzer.psd1`
- Create: `tests/Ps51Compat.Tests.ps1`

- [ ] **Step 1: Write a failing guard test that the module source contains no PS 6+ `-AsHashtable`**

Create `tests/Ps51Compat.Tests.ps1`:

```powershell
Describe 'PowerShell 5.1 source compatibility' {
    BeforeAll {
        $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
        $script:moduleFiles = Get-ChildItem -Path $script:srcDir -Filter '*.psm1' -Recurse
    }

    It 'has at least one module file to scan' {
        $script:moduleFiles.Count | Should -BeGreaterThan 0
    }

    It 'does not use ConvertFrom-Json -AsHashtable (PS 6+ only) in <Name>' -ForEach @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'src') -Filter '*.psm1' -Recurse |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        (Get-Content $Path -Raw) | Should -Not -Match '-AsHashtable'
    }
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `Invoke-Pester ./tests/Ps51Compat.Tests.ps1`
Expected: FAIL — `PurviewDlpExport.psm1` still matches `-AsHashtable`.

- [ ] **Step 3: Rewrite `Format-NormalisedKey` to drop `-AsHashtable`**

In `src/PurviewDlpExport.psm1`, replace the body of `Format-NormalisedKey` (currently lines 39-66, from `$json = $Normalised | ConvertTo-Json -Depth 20` to the final `$root | ConvertTo-Json ...`). Add a private helper above it and change the parse line. New code for the function body:

```powershell
    # PS 5.1 has no ConvertFrom-Json -AsHashtable, so build an ordered-dictionary
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
```

Add this private helper immediately **above** `Format-NormalisedKey` (e.g. after `Compress-EnumCollision`):

```powershell
function ConvertTo-OrderedTree {
    # PS 5.1-safe replacement for `ConvertFrom-Json -AsHashtable`: deep-convert a
    # PSCustomObject/array tree into [ordered] dictionaries + arrays. Recursion depth
    # tracks JSON nesting, which is shallow for DLP objects (< ~10 levels).
    [CmdletBinding()]
    param([Parameter()] $Node)

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
```

- [ ] **Step 4: Run the compat test + the full normalise suite — expect PASS**

Run: `Invoke-Pester ./tests/Ps51Compat.Tests.ps1 ./tests/Normalise.Tests.ps1`
Expected: PASS. The normalise tests prove key-sorting/byte-stability still hold with the new deep-sort; the compat test proves `-AsHashtable` is gone.

- [ ] **Step 5: Invert the version gate in the entrypoint**

In `scripts/Export-PurviewDlp.ps1`, change line 1 from `#!/usr/bin/env pwsh` to `#!/usr/bin/env powershell` (or delete the shebang line — Windows ignores it). Replace lines 13-16:

```powershell
    # Pre-flight
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PowerShell 5.1 or later required. Current: $($PSVersionTable.PSVersion)"
    }
```

- [ ] **Step 6: Set the manifest floor to 5.1**

In `src/PurviewDlpExport.psd1`, change line 7 from `PowerShellVersion = '7.0'` to `PowerShellVersion = '5.1'`.

- [ ] **Step 7: Add PSScriptAnalyzer compatibility rules as a static safety net**

Replace the contents of `.github/linters/.powershell-psscriptanalyzer.psd1` with (merges the existing exclusion with the new compat rules):

```powershell
@{
    ExcludeRules = @(
        # We intentionally write UTF-8 without BOM on all platforms.
        'PSUseBOMForUnicodeEncodedFile'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCmdlets = @{
            compatibility = @(
                'desktop-5.1.14393.206-windows',
                'core-6.1.0-windows'
            )
        }
    }
}
```

- [ ] **Step 8: Run the full suite — expect PASS**

Run: `Invoke-Pester ./tests`
Expected: PASS (all existing tests + the new compat test).

- [ ] **Step 9: Commit**

```bash
git add src/PurviewDlpExport.psm1 src/PurviewDlpExport.psd1 scripts/Export-PurviewDlp.ps1 .github/linters/.powershell-psscriptanalyzer.psd1 tests/Ps51Compat.Tests.ps1
git commit -m "feat(ps51): run on Windows PowerShell 5.1

- Replace ConvertFrom-Json -AsHashtable with a 5.1-safe ordered-tree deep-sort
- Lower the version gate and manifest floor to 5.1
- Add PSScriptAnalyzer compatibility rules as a static safety net"
```

---

## Task 2: View model — `ConvertTo-DlpView`

**Files:**
- Create: `src/PurviewDlpRender.psm1`
- Create: `tests/View.Tests.ps1`

The view builder consumes a normalised baseline (`$norm.Normalised`) and returns a resolved presentation model. It re-parses each rule's preserved `AdvancedRule` JSON for confidence/instance-count (the normaliser keeps only `{Id, Name}` for detectors), falling back to the inline resolved `ContentContainsSensitiveInformation`/`HasSensitiveInformation` for non-advanced rules.

- [ ] **Step 1: Write failing view-model tests**

Create `tests/View.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force

    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'ConvertTo-DlpView shape' {
    It 'returns the three policies' {
        $script:view.Policies.Count | Should -Be 3
    }
    It 'orders policies by priority then name' {
        $script:view.Policies[0].Name | Should -Be 'Block Credential Leakage'   # priority 0
        $script:view.Policies[2].Name | Should -Be 'Legacy Keyword Blocks'      # priority 2
    }
}

Describe 'policy-level interpretation' {
    BeforeAll { $script:p = $script:view.Policies | Where-Object Name -eq 'Block Credential Leakage' }

    It 'maps workload tokens to friendly names' {
        $script:p.Workloads | Should -Be 'Exchange, SharePoint, OneDrive'
    }
    It 'maps Enable mode to Enforce' {
        $script:p.Mode | Should -Be 'Enforce'
    }
    It 'orders child rules by priority' {
        $script:p.Rules[0].Name | Should -Be 'Block AWS Access Keys'            # priority 0
        $script:p.Rules[-1].Name | Should -Be 'Block UK PII (Advanced Rule)'    # priority 5
    }
}

Describe 'rule condition interpretation' {
    It 'renders advanced-rule confidence and instance counts' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Block Credential Leakage').Rules |
            Where-Object Name -eq 'Block UK PII (Advanced Rule)'
        $r.DetectionSummary | Should -Be "U.K. Driver's License Number, Credit Card Number"
        ($r.Conditions -join "`n") | Should -Match "U.K. Driver's License Number.*medium confidence.*10\+"
        ($r.Conditions -join "`n") | Should -Match "Credit Card Number.*high confidence.*1\+"
    }
    It 'renders orphan SIT references visibly' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Block Credential Leakage').Rules |
            Where-Object Name -eq 'Block Orphan SIT Reference'
        ($r.Conditions -join "`n") | Should -Match 'orphan id=sit-deleted-orphan-99999'
    }
    It 'renders keyword and file-extension conditions' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Legacy Keyword Blocks').Rules |
            Where-Object Name -eq 'Block Credit Card Number Phrases'
        ($r.Conditions -join "`n") | Should -Match 'card number, credit card, cvv'
        ($r.Conditions -join "`n") | Should -Match 'pan, card-number'
    }
    It 'renders label conditions and exceptions' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Sensitivity Label Enforcement').Rules |
            Where-Object Name -eq 'Block Highly Confidential External'
        ($r.Conditions -join "`n") | Should -Match 'Highly Confidential'
        ($r.Exceptions -join "`n") | Should -Match 'example\.com'
    }
}

Describe 'rule action and status interpretation' {
    It 'renders block + notify actions' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Block Credential Leakage').Rules |
            Where-Object Name -eq 'Block AWS Access Keys'
        ($r.Actions -join "`n") | Should -Match 'block'
        ($r.Actions -join "`n") | Should -Match 'LastModifier, Owner'
    }
    It 'marks a disabled rule as not enabled' {
        $r = ($script:view.Policies | Where-Object Name -eq 'Legacy Keyword Blocks').Rules |
            Where-Object Name -eq 'Block Credit Card Number Phrases'
        $r.Enabled | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `Invoke-Pester ./tests/View.Tests.ps1`
Expected: FAIL — `ConvertTo-DlpView` not defined.

- [ ] **Step 3: Implement `src/PurviewDlpRender.psm1` view builder + helpers**

Create `src/PurviewDlpRender.psm1`:

```powershell
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
                    # strip the "SIT: "/"Label: " prefix and any "(...)" detail for the summary
                    ($_ -replace '^(SIT|Label):\s*', '') -replace '\s*\(.*\)$', ''
                }) -join ', '
                [PSCustomObject]@{
                    Name             = $rule.Name
                    Mode             = Format-Mode -Mode $rule.Mode
                    Enabled          = -not ($rule.PSObject.Properties.Name -contains 'Disabled' -and $rule.Disabled)
                    Priority         = $rule.Priority
                    Comment          = if ($rule.PSObject.Properties.Name -contains 'Comment') { $rule.Comment } else { $null }
                    DetectionSummary = $summary
                    Conditions       = Get-RuleConditionLine -Rule $rule
                    Actions          = Get-RuleActionLine -Rule $rule
                    Exceptions       = Get-RuleExceptionLine -Rule $rule
                }
            })

        $scope = Get-PolicyScope -Policy $policy
        [PSCustomObject]@{
            Name      = $policy.Name
            Mode      = Format-Mode -Mode $policy.Mode
            Enabled   = [bool]$policy.Enabled
            Priority  = $policy.Priority
            Comment   = if ($policy.PSObject.Properties.Name -contains 'Comment') { $policy.Comment } else { $null }
            Workloads = Format-Workload -Workload ([string]$policy.Workload)
            Scope     = $scope
            Rules     = $childRules
        }
    })

    [PSCustomObject]@{ Policies = $policies }
}

Export-ModuleMember -Function ConvertTo-DlpView
```

- [ ] **Step 4: Run the view tests — expect PASS**

Run: `Invoke-Pester ./tests/View.Tests.ps1`
Expected: PASS (all describe blocks).

- [ ] **Step 5: Commit**

```bash
git add src/PurviewDlpRender.psm1 tests/View.Tests.ps1
git commit -m "feat(render): add ConvertTo-DlpView presentation model"
```

---

## Task 3: Overview Markdown emitter

**Files:**
- Modify: `src/PurviewDlpRender.psm1` (add `Export-DlpOverviewMarkdown`, export it)
- Create: `tests/Overview.Tests.ps1`
- Create: `tests/fixtures/expected-overview.md` (generated then locked in Step 4)

- [ ] **Step 1: Write failing behavioural tests**

Create `tests/Overview.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpOverviewMarkdown' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-ov-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-overview.md' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') | Should -BeTrue
    }
    It 'contains a table row per policy with its workloads' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $c = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        $c | Should -Match 'Block Credential Leakage'
        $c | Should -Match 'Exchange, SharePoint, OneDrive'
    }
    It 'writes UTF-8 without BOM' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:outDir 'baseline-20260601-acme-overview.md'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
    It 'is byte-identical across two runs' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-overview.md')
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw) | Should -Be $first
    }
    It 'matches the expected-overview.md snapshot byte-for-byte' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-overview.md') -Raw
        $actual | Should -Be $expected
    }
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `Invoke-Pester ./tests/Overview.Tests.ps1`
Expected: FAIL — `Export-DlpOverviewMarkdown` not defined.

- [ ] **Step 3: Implement `Export-DlpOverviewMarkdown`**

In `src/PurviewDlpRender.psm1`, add before the `Export-ModuleMember` line:

```powershell
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
```

Update the `Export-ModuleMember` line to:

```powershell
Export-ModuleMember -Function ConvertTo-DlpView, Export-DlpOverviewMarkdown
```

- [ ] **Step 4: Generate and lock the snapshot, then run the suite — expect PASS**

Generate the snapshot from real output, inspect it against the spec's overview-table shape, then lock it:

```powershell
Import-Module ./src/PurviewDlpExport.psd1 -Force
Import-Module ./src/PurviewDlpRender.psm1 -Force
$raw  = Get-Content ./tests/fixtures/raw-purview-sample.json -Raw | ConvertFrom-Json
$view = ConvertTo-DlpView -Normalised (ConvertTo-NormalisedBaseline -Inventory $raw).Normalised
Export-DlpOverviewMarkdown -View $view -OutDir ./tests/fixtures -Tenant 'acme' -DateStamp '20260601'
Move-Item -Force ./tests/fixtures/baseline-20260601-acme-overview.md ./tests/fixtures/expected-overview.md
Get-Content ./tests/fixtures/expected-overview.md
```

Confirm: a header with the three counts and one table row per policy (3 rows). Then:

Run: `Invoke-Pester ./tests/Overview.Tests.ps1`
Expected: PASS including the byte-for-byte snapshot test.

- [ ] **Step 5: Lock the snapshot to LF in `.gitattributes` and commit**

Add to `.gitattributes`:

```
tests/fixtures/expected-overview.md text eol=lf
```

```bash
git add src/PurviewDlpRender.psm1 tests/Overview.Tests.ps1 tests/fixtures/expected-overview.md .gitattributes
git commit -m "feat(render): add overview Markdown emitter"
```

---

## Task 4: Detail Markdown emitter

**Files:**
- Modify: `src/PurviewDlpRender.psm1` (add `Export-DlpDetailMarkdown`, export it)
- Create: `tests/Detail.Tests.ps1`
- Create: `tests/fixtures/expected-detail.md` (generated then locked in Step 4)

- [ ] **Step 1: Write failing behavioural tests**

Create `tests/Detail.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpDetailMarkdown' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-dt-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-detail.md' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') | Should -BeTrue
    }
    It 'renders confidence and instance counts in plain English' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $c = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        $c | Should -Match 'high confidence'
        $c | Should -Match '10\+ instances'
    }
    It 'renders the orphan reference visibly' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw) |
            Should -Match 'orphan id=sit-deleted-orphan-99999'
    }
    It 'is byte-identical across two runs' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-detail.md')
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw) | Should -Be $first
    }
    It 'matches the expected-detail.md snapshot byte-for-byte' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-detail.md') -Raw
        $actual | Should -Be $expected
    }
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `Invoke-Pester ./tests/Detail.Tests.ps1`
Expected: FAIL — `Export-DlpDetailMarkdown` not defined.

- [ ] **Step 3: Implement `Export-DlpDetailMarkdown`**

In `src/PurviewDlpRender.psm1`, add before `Export-ModuleMember`:

```powershell
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
        if ($p.Scope.Included.Count -gt 0) {
            [void]$sb.AppendLine("- Included locations:")
            foreach ($i in $p.Scope.Included) { [void]$sb.AppendLine("  - $i") }
        }
        if ($p.Scope.Excluded.Count -gt 0) {
            [void]$sb.AppendLine("- Excluded locations:")
            foreach ($x in $p.Scope.Excluded) { [void]$sb.AppendLine("  - $x") }
        }
        if ($p.Comment) { [void]$sb.AppendLine("- Comment: $($p.Comment)") }
        [void]$sb.AppendLine()

        foreach ($r in $p.Rules) {
            [void]$sb.AppendLine("### Rule: $($r.Name)")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("- Mode: $($r.Mode)")
            [void]$sb.AppendLine("- Enabled: $($r.Enabled)")
            [void]$sb.AppendLine("- Priority: $($r.Priority)")
            [void]$sb.AppendLine("- Detects: $($r.DetectionSummary)")
            [void]$sb.AppendLine("- Conditions:")
            foreach ($c in $r.Conditions) { [void]$sb.AppendLine("  - $c") }
            [void]$sb.AppendLine("- Actions:")
            foreach ($a in $r.Actions) { [void]$sb.AppendLine("  - $a") }
            if ($r.Exceptions.Count -gt 0) {
                [void]$sb.AppendLine("- Exceptions:")
                foreach ($e in $r.Exceptions) { [void]$sb.AppendLine("  - $e") }
            }
            if ($r.Comment) { [void]$sb.AppendLine("- Comment: $($r.Comment)") }
            [void]$sb.AppendLine()
        }
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-detail.md"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ DetailPath = $path }
}
```

Update the `Export-ModuleMember` line to:

```powershell
Export-ModuleMember -Function ConvertTo-DlpView, Export-DlpOverviewMarkdown, Export-DlpDetailMarkdown
```

- [ ] **Step 4: Generate and lock the snapshot, then run — expect PASS**

```powershell
Import-Module ./src/PurviewDlpExport.psd1 -Force
Import-Module ./src/PurviewDlpRender.psm1 -Force
$raw  = Get-Content ./tests/fixtures/raw-purview-sample.json -Raw | ConvertFrom-Json
$view = ConvertTo-DlpView -Normalised (ConvertTo-NormalisedBaseline -Inventory $raw).Normalised
Export-DlpDetailMarkdown -View $view -OutDir ./tests/fixtures -Tenant 'acme' -DateStamp '20260601'
Move-Item -Force ./tests/fixtures/baseline-20260601-acme-detail.md ./tests/fixtures/expected-detail.md
Get-Content ./tests/fixtures/expected-detail.md
```

Confirm: each policy has a Scope/Applies-to block; the advanced-rule shows "high confidence" / "10+ instances"; the orphan rule shows the orphan ID. Then:

Run: `Invoke-Pester ./tests/Detail.Tests.ps1`
Expected: PASS.

- [ ] **Step 5: Lock snapshot to LF and commit**

Add to `.gitattributes`:

```
tests/fixtures/expected-detail.md text eol=lf
```

```bash
git add src/PurviewDlpRender.psm1 tests/Detail.Tests.ps1 tests/fixtures/expected-detail.md .gitattributes
git commit -m "feat(render): add detail Markdown emitter"
```

---

## Task 5: CSV matrix emitter

**Files:**
- Modify: `src/PurviewDlpRender.psm1` (add `Export-DlpMatrixCsv`, export it)
- Create: `tests/Matrix.Tests.ps1`
- Create: `tests/fixtures/expected-matrix.csv` (generated then locked in Step 4)

- [ ] **Step 1: Write failing behavioural tests**

Create `tests/Matrix.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpMatrixCsv' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-csv-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-matrix.csv' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') | Should -BeTrue
    }
    It 'has a header plus one row per rule (5 rules -> 6 lines)' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $lines = (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw) -split "`n" |
            Where-Object { $_ -ne '' }
        $lines.Count | Should -Be 6
    }
    It 'has the agreed columns in the header' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $header = ((Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv')) | Select-Object -First 1)
        $header | Should -Be 'Policy,Rule,Workloads,Enabled,Mode,Priority,Detects,Conditions,Actions,Exceptions'
    }
    It 'is byte-identical across two runs' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv')
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw) | Should -Be $first
    }
    It 'matches the expected-matrix.csv snapshot byte-for-byte' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-matrix.csv') -Raw
        $actual | Should -Be $expected
    }
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `Invoke-Pester ./tests/Matrix.Tests.ps1`
Expected: FAIL — `Export-DlpMatrixCsv` not defined.

- [ ] **Step 3: Implement `Export-DlpMatrixCsv`**

CSV is built by hand (not `Export-Csv`) for full control of quoting, ordering, and LF endings. In `src/PurviewDlpRender.psm1`, add before `Export-ModuleMember`:

```powershell
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
                (ConvertTo-CsvField ($r.Conditions -join '; ')),
                (ConvertTo-CsvField ($r.Actions -join '; ')),
                (ConvertTo-CsvField ($r.Exceptions -join '; '))
            ) -join ','
            [void]$sb.Append("$row`n")
        }
    }

    $path = Join-Path $OutDir "baseline-$DateStamp-$Tenant-matrix.csv"
    Write-NoBomLf -Path $path -Content $sb.ToString()
    [PSCustomObject]@{ MatrixPath = $path }
}
```

Note: the snapshot test compares raw content; the "header" test reads the first line. Because every field is quoted, the header test asserts the *unquoted* logical header — adjust: the header line as written is the literal `Policy,Rule,...` (unquoted, from the `Append` above), so the `Should -Be 'Policy,Rule,...'` test passes. Data rows are quoted.

Update the `Export-ModuleMember` line to:

```powershell
Export-ModuleMember -Function ConvertTo-DlpView, Export-DlpOverviewMarkdown, Export-DlpDetailMarkdown, Export-DlpMatrixCsv
```

- [ ] **Step 4: Generate and lock the snapshot, then run — expect PASS**

```powershell
Import-Module ./src/PurviewDlpExport.psd1 -Force
Import-Module ./src/PurviewDlpRender.psm1 -Force
$raw  = Get-Content ./tests/fixtures/raw-purview-sample.json -Raw | ConvertFrom-Json
$view = ConvertTo-DlpView -Normalised (ConvertTo-NormalisedBaseline -Inventory $raw).Normalised
Export-DlpMatrixCsv -View $view -OutDir ./tests/fixtures -Tenant 'acme' -DateStamp '20260601'
Move-Item -Force ./tests/fixtures/baseline-20260601-acme-matrix.csv ./tests/fixtures/expected-matrix.csv
Get-Content ./tests/fixtures/expected-matrix.csv
```

Confirm: 1 header line + 5 data rows; multi-value Conditions/Actions cells stay inside one quoted field. Then:

Run: `Invoke-Pester ./tests/Matrix.Tests.ps1`
Expected: PASS.

- [ ] **Step 5: Lock snapshot to LF and commit**

Add to `.gitattributes`:

```
tests/fixtures/expected-matrix.csv text eol=lf
```

```bash
git add src/PurviewDlpRender.psm1 tests/Matrix.Tests.ps1 tests/fixtures/expected-matrix.csv .gitattributes
git commit -m "feat(render): add CSV matrix emitter"
```

---

## Task 6: Wire into the entrypoint, retire the old Markdown export, update docs

**Files:**
- Modify: `scripts/Export-PurviewDlp.ps1` (import render module, call the three emitters)
- Modify: `src/PurviewDlpExport.psm1` (remove `Export-DlpBaselineMarkdown`, `Format-RuleCondition`, `Format-RuleAction`, and the matching `Export-ModuleMember` entry)
- Delete: `tests/ExportMarkdown.Tests.ps1`, `tests/fixtures/expected.md`
- Modify: `.gitignore` (ignore `baseline-*.csv`)
- Modify: `.gitattributes` (drop the now-deleted `tests/fixtures/expected.md` line)
- Modify: `README.md`, `docs/docs/output-schema.md`, `docs/docs/CHANGELOG.md`

- [ ] **Step 1: Remove the old Markdown export and its test**

In `src/PurviewDlpExport.psm1`, delete the functions `Format-RuleCondition` (lines ~451-482), `Format-RuleAction` (~484-500), and `Export-DlpBaselineMarkdown` (~502-572). Update the `Export-ModuleMember` block at the bottom to drop `Export-DlpBaselineMarkdown`:

```powershell
Export-ModuleMember -Function `
    Connect-PurviewDlpSession, `
    Get-DlpInventory, `
    ConvertTo-NormalisedBaseline, `
    Export-DlpBaselineJson
```

Delete the files:

```bash
git rm tests/ExportMarkdown.Tests.ps1 tests/fixtures/expected.md
```

In `.gitattributes`, remove the line `tests/fixtures/expected.md text eol=lf`.

- [ ] **Step 2: Ignore CSV outputs**

In `.gitignore`, under the baseline-outputs block, add `baseline-*.csv` next to the existing `baseline-*.md` lines:

```
baseline-*.json
baseline-*.meta.json
baseline-*.md
baseline-*.csv
```

- [ ] **Step 3: Wire the entrypoint to the new emitters**

In `scripts/Export-PurviewDlp.ps1`, after the existing `Import-Module $modulePath -Force` (line ~26), add the render module import:

```powershell
    $renderPath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1'
    Import-Module $renderPath -Force
```

Replace the emit block (the current `Export-DlpBaselineMarkdown` call and the surrounding `$mdOut`/Write-Host lines, ~55-64) with:

```powershell
    $view = ConvertTo-DlpView -Normalised $normResult.Normalised

    $overviewOut = Export-DlpOverviewMarkdown -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp
    $detailOut   = Export-DlpDetailMarkdown   -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp
    $matrixOut   = Export-DlpMatrixCsv        -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp

    Write-Host "Wrote:"
    Write-Host "  $($jsonOut.JsonPath)"
    Write-Host "  $($jsonOut.MetaPath)"
    Write-Host "  $($overviewOut.OverviewPath)"
    Write-Host "  $($detailOut.DetailPath)"
    Write-Host "  $($matrixOut.MatrixPath)"
```

- [ ] **Step 4: Add an entrypoint integration test**

Create `tests/Entrypoint.Tests.ps1`:

```powershell
Describe 'Export-PurviewDlp.ps1 emitter wiring' {
    It 'references all three new emitters and no longer calls the retired Markdown export' {
        $script = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-PurviewDlp.ps1') -Raw
        $script | Should -Match 'Export-DlpOverviewMarkdown'
        $script | Should -Match 'Export-DlpDetailMarkdown'
        $script | Should -Match 'Export-DlpMatrixCsv'
        $script | Should -Not -Match 'Export-DlpBaselineMarkdown'
    }
}
```

- [ ] **Step 5: Run the full suite — expect PASS**

Run: `Invoke-Pester ./tests`
Expected: PASS. No references to the deleted `expected.md`/`Export-DlpBaselineMarkdown` remain.

- [ ] **Step 6: Update docs**

In `README.md`: update the "Produces in `./out/`" list to the five files (`.json`, `.meta.json`, `-overview.md`, `-detail.md`, `-matrix.csv`); change the Requirements line from "PowerShell 7.x" to "PowerShell 5.1 or later (Windows PowerShell 5.1 supported)"; in the smoke-test section, change "Verify three files were written" to verify the five files. In `docs/docs/output-schema.md`: document the three new outputs and the CSV columns. In `docs/docs/CHANGELOG.md`: add an entry for PS 5.1 support + layered human-readable output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: emit layered overview/detail/CSV outputs; retire single Markdown export

- Entrypoint builds the view model once and writes overview.md, detail.md, matrix.csv
- Remove Export-DlpBaselineMarkdown and its snapshot in favour of the layered emitters
- Ignore baseline-*.csv; update README, output-schema, CHANGELOG"
```

---

## Manual verification (after all tasks, on the PS 5.1 target box)

Run the readme "Manual smoke test" on Windows PowerShell 5.1:
1. Confirm the export runs to completion under `$PSVersionTable.PSVersion.Major -eq 5`.
2. Confirm five files are written: `.json`, `.meta.json`, `-overview.md`, `-detail.md`, `-matrix.csv`.
3. Confirm the meta sidecar `ToolVersion` matches `ModuleVersion` in the manifest.
4. Re-run and confirm each output diffs empty against the first run (same-box byte-stability).
5. Skim the overview (scan the estate), detail (understand a rule), and open the CSV in Excel.

---

## Self-review notes

- **Spec coverage:** PS 5.1 port → Task 1. View model → Task 2. Overview/detail/CSV → Tasks 3/4/5. Entrypoint + docs + gitignore CSV → Task 6. Manual PS 5.1 verification → final section.
- **Deferred (iterate later, per "start then iterate"):** richer scope (per-location include/exclude) and encrypt/RMS/policy-tip actions are rendered *if present* but not exercised by the current fixture — they light up against real tenant data in the smoke test. Enriching `raw-purview-sample.json` to cover them (and regenerating all three snapshots together) is a fast follow-up.
- **Byte-stability:** every emitter has a two-run determinism test and a no-BOM check; snapshots are LF-locked via `.gitattributes`.
