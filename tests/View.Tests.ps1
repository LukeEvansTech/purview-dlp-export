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
