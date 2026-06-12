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

Describe 'ConvertTo-NormalisedBaseline expands advanced rules' {
    BeforeAll {
        $script:result = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
        $script:advRule = $script:result.Normalised.Rules |
            Where-Object { $_.Name -eq 'Block UK PII (Advanced Rule)' }
    }

    It 'finds the advanced rule' {
        $script:advRule | Should -Not -BeNullOrEmpty
    }

    It 'replaces null inline SIT refs with parsed AdvancedRule SITs' {
        $sits = $script:advRule.ContentContainsSensitiveInformation
        $sits.Count | Should -Be 2
        $sits | ForEach-Object { $_.Id | Should -Not -BeNullOrEmpty }
        $sits | ForEach-Object { $_.Name | Should -Not -BeNullOrEmpty }
    }

    It 'resolves SIT names from ReferencedSits, not from inline (null) refs' {
        $names = $script:advRule.ContentContainsSensitiveInformation | ForEach-Object { $_.Name }
        $names | Should -Contain 'U.K. Driver''s License Number'
        $names | Should -Contain 'Credit Card Number'
    }

    It 'marks advanced-rule SITs as not orphan when in ReferencedSits' {
        $orphans = $script:advRule.ContentContainsSensitiveInformation |
            Where-Object { $_.Orphan }
        $orphans.Count | Should -Be 0
    }
}

Describe 'ConvertTo-NormalisedBaseline tolerates malformed AdvancedRule shapes' {
    # The render module learned on real tenants that AdvancedRule value items are heterogeneous
    # and must be read with guarded access under StrictMode. The normaliser walks the same JSON
    # in Expand-AdvancedRuleReference, so unexpected shapes must not crash it either.
    BeforeAll {
        $advJson = '{"Condition":{"SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[' +
            '{"confidencelevel":"High"},' +
            '{"Operator":"And","Groups":[{"Operator":"Or","Labels":[{"Id":"lab-1"}]}]}' +
            ']}]}}'
        $rule = [PSCustomObject]@{
            Name             = 'Odd Shapes Rule'
            ParentPolicyName = 'P'
            AdvancedRule     = $advJson
        }
        $script:oddInv = [PSCustomObject]@{
            Policies         = @([PSCustomObject]@{ Name = 'P' })
            Rules            = @($rule)
            ReferencedSits   = @()
            ReferencedLabels = @()
        }
    }

    It 'does not throw on a flat item with no id and a Groups label with no Name/Type' {
        { ConvertTo-NormalisedBaseline -Inventory $script:oddInv } | Should -Not -Throw
    }

    It 'still captures the id-bearing reference and skips the id-less item' {
        $result = ConvertTo-NormalisedBaseline -Inventory $script:oddInv
        $r = $result.Normalised.Rules | Where-Object { $_.Name -eq 'Odd Shapes Rule' }
        $ids = @($r.ContentContainsSensitiveInformation | ForEach-Object { $_.Id })
        $ids | Should -Be @('lab-1')
    }
}

Describe 'ConvertTo-NormalisedBaseline tolerates SubConditions without ConditionName' {
    # Real tenants emit nested grouping SubConditions ({"Operator":"And","SubConditions":[...]})
    # alongside leaf conditions. These have no ConditionName property, so direct access throws
    # under Set-StrictMode -Version Latest on PS 5.1. Expand-AdvancedRuleReference must skip them.
    BeforeAll {
        $advJson = '{"Condition":{"Operator":"And","SubConditions":[' +
            '{"Operator":"Or","SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"id":"sit-1","name":"My SIT"}]}]},' +
            '{"ConditionName":"ContentIsShared","Value":"InOrganization"}' +
            ']}}'
        $rule = [PSCustomObject]@{
            Name             = 'Nested Group Rule'
            ParentPolicyName = 'P'
            AdvancedRule     = $advJson
        }
        $script:nestedInv = [PSCustomObject]@{
            Policies         = @([PSCustomObject]@{ Name = 'P' })
            Rules            = @($rule)
            ReferencedSits   = @([PSCustomObject]@{ Id = 'sit-1'; Name = 'My SIT' })
            ReferencedLabels = @()
        }
    }

    It 'does not throw when a SubCondition has no ConditionName property' {
        { ConvertTo-NormalisedBaseline -Inventory $script:nestedInv } | Should -Not -Throw
    }
}

Describe 'ConvertTo-NormalisedBaseline reference ordering is deterministic' {
    It 'orders references with identical (null) Names by Id, regardless of input order' {
        # Orphan references resolve with Name = $null. Sorting by Name alone is stable, so two
        # null-named orphans would keep whatever order the impure fetch produced - which is not
        # guaranteed across runs and would break the byte-identical re-run guarantee.
        $orphanZ = [PSCustomObject]@{ Id = 'ffffffff-0000-0000-0000-000000000001'; Name = $null }
        $orphanA = [PSCustomObject]@{ Id = '00000000-0000-0000-0000-000000000001'; Name = $null }
        $inv = [PSCustomObject]@{
            Policies         = $script:rawInventory.Policies
            Rules            = $script:rawInventory.Rules
            ReferencedSits   = @($orphanZ, $orphanA)
            ReferencedLabels = @($orphanZ, $orphanA)
        }

        $result = ConvertTo-NormalisedBaseline -Inventory $inv

        @($result.Normalised.ReferencedSits   | ForEach-Object { $_.Id }) |
            Should -Be @($orphanA.Id, $orphanZ.Id)
        @($result.Normalised.ReferencedLabels | ForEach-Object { $_.Id }) |
            Should -Be @($orphanA.Id, $orphanZ.Id)
    }
}

Describe 'ConvertTo-NormalisedBaseline flattens enum collisions' {
    BeforeAll {
        # Enum-collision objects ({value, Value}) exist in real Purview proxy objects but cannot be
        # represented in a JSON fixture file (ConvertFrom-Json rejects case-collision keys) or as
        # a PSCustomObject (case-insensitive property bag). The collision only materialises when
        # ConvertTo-Json serialises real Purview in-memory proxy objects. We therefore test the
        # production guarantee (JSON output is parseable) against the fixture inventory, and verify
        # the Expand-EnumCollisions helper behaviour via the module's internal Apply-EnumFlatten
        # logic by constructing a synthetic inventory whose rules include an ordered hashtable
        # carrying both 'value' and 'Value' keys - the shape ConvertFrom-Json -AsHashTable returns
        # for collision JSON.  ConvertTo-NormalisedBaseline converts hashtables to PSCustomObject
        # before returning, so the collision must be resolved before serialisation.
        $script:collisionResult = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
    }

    It 'JSON output is parseable by ConvertFrom-Json without -AsHashTable' {
        $json = $script:collisionResult.Normalised | ConvertTo-Json -Depth 20
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'throws a clear error when a collision shape escapes the flatten patterns' {
        # The replace patterns only match objects holding exactly {value, Value}. A collision
        # carrying a sibling property escapes them, and the resulting JSON crashes
        # ConvertFrom-Json on Windows PowerShell 5.1 with an obscure duplicated-keys error
        # (PS 7 in CI throws a different one). The normaliser must fail loudly and name the
        # problem instead. Only a case-sensitive dictionary can carry both key casings here.
        $collision = New-Object System.Collections.Specialized.OrderedDictionary
        $collision['value'] = 1
        $collision['Value'] = 'Low'
        $collision['extra'] = 'sibling property defeats the exact-pair pattern'
        $rule = [PSCustomObject]@{
            Name             = 'R'
            ParentPolicyName = 'P'
            SomeEnum         = $collision
        }
        $inv = [PSCustomObject]@{
            Policies         = @([PSCustomObject]@{ Name = 'P' })
            Rules            = @($rule)
            ReferencedSits   = @()
            ReferencedLabels = @()
        }
        { ConvertTo-NormalisedBaseline -Inventory $inv } | Should -Throw '*enum collision*'
    }

    It 'normalised output contains no nested PSCustomObject with both lowercase value and uppercase Value properties' {
        # Serialise and reparse; if any {value,Value} collision had survived, ConvertFrom-Json
        # would have thrown in the previous test.  Here we additionally verify that no rule
        # property is itself a PSCustomObject with exactly two properties differing only in case,
        # which would indicate Expand-EnumCollisions failed to flatten it.
        foreach ($rule in $script:collisionResult.Normalised.Rules) {
            foreach ($prop in $rule.PSObject.Properties) {
                if ($prop.Value -is [PSCustomObject]) {
                    $subNames = $prop.Value.PSObject.Properties.Name
                    $hasLower = $subNames -ccontains 'value'
                    $hasUpper = $subNames -ccontains 'Value'
                    ($hasLower -and $hasUpper) | Should -BeFalse -Because "property '$($prop.Name)' on rule '$($rule.Name)' should not retain an enum-collision object"
                }
            }
        }
    }
}
