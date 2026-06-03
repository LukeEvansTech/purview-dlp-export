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

Describe 'regression: de-greedy DetectionSummary regex' {
    It 'preserves acronym parens in SIT names (e.g. SSN)' {
        # Realistic normalised shape: the normaliser backfills an inline, resolved
        # ContentContainsSensitiveInformation (the source of names) and preserves the raw
        # AdvancedRule (the source of confidence/instance-count, looked up by id). The detector
        # name "U.S. Social Security Number (SSN)" must appear verbatim in DetectionSummary
        # (acronym preserved), while the appended "(high confidence, 1+ instances)" detail must
        # appear only in the full Conditions line, never folded into the summary.
        $advancedRule = @{
            Condition = @{
                SubConditions = @(
                    @{
                        ConditionName = 'ContentContainsSensitiveInformation'
                        Value         = @(
                            @{
                                id              = 'sit-ssn'
                                name            = 'U.S. Social Security Number (SSN)'
                                confidencelevel = 'High'
                                mincount        = '1'
                                maxcount        = '-1'
                            }
                        )
                    }
                )
            }
        } | ConvertTo-Json -Depth 10

        $normInput = [PSCustomObject]@{
            Policies = @(
                [PSCustomObject]@{
                    Name     = 'Test Policy'
                    Mode     = 'Enable'
                    Enabled  = $true
                    Priority = 0
                    Workload = 'Exchange'
                }
            )
            Rules = @(
                [PSCustomObject]@{
                    Name             = 'Test Rule'
                    ParentPolicyName = 'Test Policy'
                    Mode             = 'Enable'
                    Priority         = 0
                    AdvancedRule     = $advancedRule
                    ContentContainsSensitiveInformation = @(
                        [PSCustomObject]@{ Name = 'U.S. Social Security Number (SSN)'; id = 'sit-ssn' }
                    )
                }
            )
            ReferencedSits   = @()
            ReferencedLabels = @()
        }

        $v = ConvertTo-DlpView -Normalised $normInput
        $rule = $v.Policies[0].Rules[0]
        # Acronym preserved, confidence detail NOT folded into the summary:
        $rule.DetectionSummary | Should -Be 'U.S. Social Security Number (SSN)'
        # Confidence/count enriched by id and shown in the full condition line:
        ($rule.Conditions -join "`n") | Should -Match 'U\.S\. Social Security Number \(SSN\) \(high confidence, 1\+ instances\)'
    }
}

Describe 'regression: non-advanced SIT acronym preserved in DetectionSummary' {
    It 'preserves acronym parens in non-advanced SIT name with no confidence/count suffix' {
        # A non-advanced rule (no AdvancedRule) whose SIT name contains parens "(SSN)".
        # With no detail suffix appended, the old regex would incorrectly strip the acronym.
        # The new structured approach derives DetectionSummary directly from the Name field.
        $normInput = [PSCustomObject]@{
            Policies = @(
                [PSCustomObject]@{
                    Name     = 'Test Policy'
                    Mode     = 'Enable'
                    Enabled  = $true
                    Priority = 0
                    Workload = 'Exchange'
                }
            )
            Rules = @(
                [PSCustomObject]@{
                    Name                                = 'Test Rule'
                    ParentPolicyName                    = 'Test Policy'
                    Mode                                = 'Enable'
                    Priority                            = 0
                    ContentContainsSensitiveInformation = @(
                        [PSCustomObject]@{ name = 'U.S. Social Security Number (SSN)'; id = 'sit-ssn' }
                    )
                }
            )
            ReferencedSits   = @()
            ReferencedLabels = @()
        }

        $v = ConvertTo-DlpView -Normalised $normInput
        $rule = $v.Policies[0].Rules[0]
        $rule.DetectionSummary | Should -Be 'U.S. Social Security Number (SSN)'
    }
}

Describe 'regression: missing optional fields do not throw' {
    It 'handles policy and rule with no Enabled/Workload/Priority/Mode without throwing' {
        # A policy with only Name and a rule with only Name + ParentPolicyName.
        # All optional fields (Enabled, Workload, Priority, Mode) are absent.
        $normInput = [PSCustomObject]@{
            Policies = @(
                [PSCustomObject]@{
                    Name = 'Bare Policy'
                }
            )
            Rules = @(
                [PSCustomObject]@{
                    Name             = 'Bare Rule'
                    ParentPolicyName = 'Bare Policy'
                }
            )
            ReferencedSits   = @()
            ReferencedLabels = @()
        }

        { ConvertTo-DlpView -Normalised $normInput } | Should -Not -Throw

        $v    = ConvertTo-DlpView -Normalised $normInput
        $pol  = $v.Policies[0]
        $rule = $pol.Rules[0]

        # Absent Mode on policy -> '(unknown)'; absent Workload -> '(none)'
        $pol.Mode     | Should -Be '(unknown)'
        $pol.Workloads | Should -Be '(none)'

        # Absent Mode on rule -> '(unknown)'
        $rule.Mode | Should -Be '(unknown)'
    }
}

Describe 'regression: advanced-rule nested Groups (label) shape does not crash' {
    # Mirrors the real Purview shape (codelooks "Highly Confidential" rule): a sensitivity-label
    # condition is stored in AdvancedRule as a nested { Operator, Groups:[{ Labels:[{Name,Id,Type}] }] }
    # item with NO top-level 'name'. The old Get-RuleDetector iterated these items and accessed
    # $item.name, throwing under StrictMode. Names/kinds must instead come from the normaliser's
    # resolved HasSensitiveInformation.
    BeforeAll {
        $advJson = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"Operator":"And","Groups":[{"Name":"Default","Operator":"Or","Labels":[{"Name":"11111111-1111-1111-1111-111111111111","Id":"11111111-1111-1111-1111-111111111111","Type":"Sensitivity"}]}]}]}]}}'
        $rule = [PSCustomObject]@{
            Name             = 'Label Rule'
            ParentPolicyName = 'P'
            Mode             = 'Enable'
            Priority         = 0
            Disabled         = $false
            AdvancedRule     = $advJson
            HasSensitiveInformation = @([PSCustomObject]@{ Name = 'Highly Confidential'; id = '11111111-1111-1111-1111-111111111111'; type = 'label'; Orphan = $false })
            BlockAccess      = $true
        }
        $policy = [PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true; Priority = 0; Workload = 'Exchange' }
        $script:normInput = [PSCustomObject]@{ Policies = @($policy); Rules = @($rule); ReferencedSits = @(); ReferencedLabels = @() }
    }

    It 'does not throw on the nested Groups shape' {
        { ConvertTo-DlpView -Normalised $script:normInput } | Should -Not -Throw
    }

    It 'renders the resolved label name from HasSensitiveInformation' {
        $view = ConvertTo-DlpView -Normalised $script:normInput
        $r = $view.Policies[0].Rules[0]
        ($r.Conditions -join "`n") | Should -Match 'Label: Highly Confidential'
        $r.DetectionSummary | Should -Be 'Highly Confidential'
    }
}

Describe 'policy scope renders location objects in plain terms' {
    BeforeAll {
        # Real Purview *Location values are rich objects, not strings. Render their DisplayName
        # (or Name), never the raw @{...} object dump.
        $policy = [PSCustomObject]@{
            Name     = 'P'
            Mode     = 'Enable'
            Enabled  = $true
            Priority = 0
            Workload = 'Exchange'
            ExchangeLocation          = @([PSCustomObject]@{ DisplayName = 'All'; Name = 'All'; Type = 'Tenant' })
            SharePointLocation        = @([PSCustomObject]@{ DisplayName = 'Finance Site'; Name = 'https://x.sharepoint.com/finance' })
            ExchangeLocationException = @([PSCustomObject]@{ DisplayName = 'Execs'; Name = 'execs@x.com' })
        }
        $rule = [PSCustomObject]@{ Name = 'R'; ParentPolicyName = 'P'; Mode = 'Enable'; Priority = 0; BlockAccess = $true }
        $norm = [PSCustomObject]@{ Policies = @($policy); Rules = @($rule); ReferencedSits = @(); ReferencedLabels = @() }
        $script:scope = (ConvertTo-DlpView -Normalised $norm).Policies[0].Scope
    }

    It 'renders DisplayName for included locations, not the object dump' {
        $script:scope.Included | Should -Contain 'ExchangeLocation: All'
        $script:scope.Included | Should -Contain 'SharePointLocation: Finance Site'
    }
    It 'renders excluded locations the same way' {
        $script:scope.Excluded | Should -Contain 'ExchangeLocationException: Execs'
    }
    It 'never emits a raw hashtable dump' {
        (($script:scope.Included + $script:scope.Excluded) -join "`n") | Should -Not -Match '@\{'
    }
}

Describe 'condition lines suppress empty keyword/extension fields' {
    It 'omits an empty File extensions line' {
        $rule = [PSCustomObject]@{
            Name = 'R'; ParentPolicyName = 'P'; Mode = 'Enable'; Priority = 0
            ContentContainsSensitiveInformation = @([PSCustomObject]@{ Name = 'Credit Card Number'; id = 'sit-cc' })
            ContentExtensionMatchesWords = @()   # present but empty
            ContentMatchesKeywords       = @()
        }
        $policy = [PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true; Priority = 0; Workload = 'Exchange' }
        $norm = [PSCustomObject]@{ Policies = @($policy); Rules = @($rule); ReferencedSits = @(); ReferencedLabels = @() }
        $conds = (ConvertTo-DlpView -Normalised $norm).Policies[0].Rules[0].Conditions -join "`n"
        $conds | Should -Match 'Credit Card Number'
        $conds | Should -Not -Match 'File extensions:'
        $conds | Should -Not -Match 'Keywords:'
    }
}
