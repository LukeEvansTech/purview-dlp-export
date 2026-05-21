BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1'
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

Describe 'ConvertTo-NormalisedBaseline preserves semantic fields' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $script:awsRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block AWS Access Keys' }
        $script:labelRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block Highly Confidential External' }
        $script:keywordRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block Credit Card Number Phrases' }
        $script:legacyPolicy = $script:result.Normalised.Policies |
            Where-Object { $_.Name -eq 'Legacy Keyword Blocks' }
    }

    It 'preserves rule Name, Mode, Priority on a SIT rule' {
        $script:awsRule.Name     | Should -Be 'Block AWS Access Keys'
        $script:awsRule.Mode     | Should -Be 'Enable'
        $script:awsRule.Priority | Should -Be 0
    }

    It 'preserves Disabled flag on rules' {
        $script:awsRule.Disabled    | Should -BeFalse
        $script:keywordRule.Disabled | Should -BeTrue
    }

    It 'preserves BlockAccess and NotifyUser actions' {
        $script:awsRule.BlockAccess | Should -BeTrue
        $script:awsRule.NotifyUser  | Should -Be @('LastModifier', 'Owner')
    }

    It 'preserves Comment field' {
        $script:awsRule.Comment | Should -Be 'Tier-1.'
    }

    It 'preserves exception clauses' {
        $script:labelRule.ExceptIfRecipientDomainIs | Should -Be @('example.com')
    }

    It 'preserves GenerateIncidentReport on the keyword rule' {
        $script:keywordRule.GenerateIncidentReport | Should -Be @('Owner')
    }

    It 'preserves policy-level Enabled flag (including false)' {
        $script:legacyPolicy.Enabled | Should -BeFalse
    }
}

Describe 'ConvertTo-NormalisedBaseline StrippedFields manifest' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
    }

    It 'lists every field that was actually removed from policies' {
        $rawPolicyFields = $script:rawInventory.Policies[0].PSObject.Properties.Name
        $normPolicyFields = $script:result.Normalised.Policies[0].PSObject.Properties.Name
        $actuallyRemoved = $rawPolicyFields | Where-Object { $_ -notin $normPolicyFields }

        # Every field the function CLAIMS to strip must actually be absent from output:
        foreach ($field in $script:result.StrippedFields) {
            $normPolicyFields | Should -Not -Contain $field
        }
        # And every field that was actually removed must be listed in StrippedFields:
        foreach ($field in $actuallyRemoved) {
            $script:result.StrippedFields | Should -Contain $field
        }
    }

    It 'lists every field that was actually removed from rules' {
        $rawRuleFields = $script:rawInventory.Rules[0].PSObject.Properties.Name
        $normRuleFields = $script:result.Normalised.Rules[0].PSObject.Properties.Name
        $actuallyRemoved = $rawRuleFields | Where-Object { $_ -notin $normRuleFields }

        foreach ($field in $script:result.StrippedFields) {
            $normRuleFields | Should -Not -Contain $field
        }
        foreach ($field in $actuallyRemoved) {
            $script:result.StrippedFields | Should -Contain $field
        }
    }
}

Describe 'ConvertTo-NormalisedBaseline handles empty reference collections' {
    It 'does not throw when ReferencedLabels is empty' {
        $inv = [PSCustomObject]@{
            Policies         = $script:rawInventory.Policies
            Rules            = $script:rawInventory.Rules
            ReferencedSits   = $script:rawInventory.ReferencedSits
            ReferencedLabels = @()
        }
        { ConvertTo-NormalisedBaseline -Inventory $inv } | Should -Not -Throw
    }

    It 'does not throw when ReferencedSits is empty' {
        $inv = [PSCustomObject]@{
            Policies         = $script:rawInventory.Policies
            Rules            = $script:rawInventory.Rules
            ReferencedSits   = @()
            ReferencedLabels = $script:rawInventory.ReferencedLabels
        }
        { ConvertTo-NormalisedBaseline -Inventory $inv } | Should -Not -Throw
    }

    It 'does not throw when both ReferencedSits and ReferencedLabels are empty' {
        $inv = [PSCustomObject]@{
            Policies         = $script:rawInventory.Policies
            Rules            = $script:rawInventory.Rules
            ReferencedSits   = @()
            ReferencedLabels = @()
        }
        { ConvertTo-NormalisedBaseline -Inventory $inv } | Should -Not -Throw
    }
}
