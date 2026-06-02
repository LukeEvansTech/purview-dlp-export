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
        # Build a minimal normalised baseline with one policy and one rule whose
        # AdvancedRule carries a SIT named "U.S. Social Security Number (SSN)".
        # The appended detail "(high confidence, 1+ instances)" must be stripped,
        # but the acronym "(SSN)" that is part of the name must be preserved.
        $advancedRule = @{
            Condition = @{
                SubConditions = @(
                    @{
                        ConditionName = 'ContentContainsSensitiveInformation'
                        Value         = @(
                            @{
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
