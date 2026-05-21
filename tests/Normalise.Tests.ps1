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

Describe 'ConvertTo-NormalisedBaseline orphan handling' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $script:orphanRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block Orphan SIT Reference' }
    }

    It 'finds the orphan rule in the normalised output' {
        $script:orphanRule | Should -Not -BeNullOrEmpty
    }

    It 'marks the orphan SIT reference with Orphan = true' {
        $sitRef = $script:orphanRule.ContentContainsSensitiveInformation[0]
        $sitRef.PSObject.Properties.Name | Should -Contain 'Orphan'
        $sitRef.Orphan | Should -BeTrue
    }

    It 'leaves non-orphan SIT references with Orphan = false' {
        $awsRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block AWS Access Keys' }
        $sitRef = $awsRule.ContentContainsSensitiveInformation[0]
        $sitRef.Orphan | Should -BeFalse
    }
}

Describe 'ConvertTo-NormalisedBaseline idempotency and byte-stability' {
    It 'is idempotent: Normalise(Normalise(x)) == Normalise(x)' {
        $once  = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $twice = ConvertTo-NormalisedBaseline -Inventory $once.Normalised

        $jsonOnce  = $once.Normalised  | ConvertTo-Json -Depth 20
        $jsonTwice = $twice.Normalised | ConvertTo-Json -Depth 20

        $jsonTwice | Should -Be $jsonOnce
    }

    It 'produces byte-identical JSON on two runs against the same input' {
        $a = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $b = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory

        $jsonA = $a.Normalised | ConvertTo-Json -Depth 20
        $jsonB = $b.Normalised | ConvertTo-Json -Depth 20

        $jsonB | Should -Be $jsonA
    }
}
