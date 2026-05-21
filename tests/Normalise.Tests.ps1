BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psm1'
    Import-Module $modulePath -Force

    $fixturePath = Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json'
    $script:rawInventory = Get-Content $fixturePath -Raw | ConvertFrom-Json
}

Describe 'ConvertTo-NormalisedBaseline shape' {
    It 'returns an object with Normalised and StrippedFields properties' {
        $result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $result.PSObject.Properties.Name | Should -Contain 'Normalised'
        $result.PSObject.Properties.Name | Should -Contain 'StrippedFields'
    }

    It 'preserves the four top-level inventory sections' {
        $result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $result.Normalised.PSObject.Properties.Name | Should -Contain 'Policies'
        $result.Normalised.PSObject.Properties.Name | Should -Contain 'Rules'
        $result.Normalised.PSObject.Properties.Name | Should -Contain 'ReferencedSits'
        $result.Normalised.PSObject.Properties.Name | Should -Contain 'ReferencedLabels'
    }
}

Describe 'ConvertTo-NormalisedBaseline strips volatile fields from policies' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
    }

    It 'strips <Field> from every policy' -ForEach @(
        @{ Field = 'RunspaceId' }
        @{ Field = 'ETag' }
        @{ Field = 'WhenCreatedUTC' }
        @{ Field = 'WhenChangedUTC' }
        @{ Field = 'ObjectVersion' }
        @{ Field = 'ImmutableId' }
    ) {
        foreach ($policy in $script:result.Normalised.Policies) {
            $policy.PSObject.Properties.Name | Should -Not -Contain $Field
        }
    }
}

Describe 'ConvertTo-NormalisedBaseline strips volatile fields from rules' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
    }

    It 'strips <Field> from every rule' -ForEach @(
        @{ Field = 'RunspaceId' }
        @{ Field = 'ETag' }
        @{ Field = 'WhenCreatedUTC' }
        @{ Field = 'WhenChangedUTC' }
        @{ Field = 'ObjectVersion' }
        @{ Field = 'ImmutableId' }
    ) {
        foreach ($rule in $script:result.Normalised.Rules) {
            $rule.PSObject.Properties.Name | Should -Not -Contain $Field
        }
    }
}

Describe 'ConvertTo-NormalisedBaseline sort order' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
    }

    It 'sorts policies by Name ascending' {
        $names = $script:result.Normalised.Policies | ForEach-Object { $_.Name }
        $sorted = $names | Sort-Object
        $names | Should -Be $sorted
    }

    It 'sorts rules by ParentPolicyName then Name ascending' {
        $keys = $script:result.Normalised.Rules | ForEach-Object {
            "$($_.ParentPolicyName)::$($_.Name)"
        }
        $sorted = $keys | Sort-Object
        $keys | Should -Be $sorted
    }

    It 'sorts property keys alphabetically within each policy' {
        foreach ($policy in $script:result.Normalised.Policies) {
            $names = $policy.PSObject.Properties.Name
            $sorted = $names | Sort-Object
            $names | Should -Be $sorted
        }
    }

    It 'sorts property keys alphabetically within each rule' {
        foreach ($rule in $script:result.Normalised.Rules) {
            $names = $rule.PSObject.Properties.Name
            $sorted = $names | Sort-Object
            $names | Should -Be $sorted
        }
    }
}
