BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1'
    Import-Module $modulePath -Force

    # The Purview cmdlets do not exist off-tenant. Define global stubs so Pester can mock them
    # in the module's scope; the stubs accept the parameters the module passes so binding works.
    function global:Get-DlpCompliancePolicy { [CmdletBinding()] param() }
    function global:Get-DlpComplianceRule { [CmdletBinding()] param() }
    function global:Get-DlpSensitiveInformationType { [CmdletBinding()] param($Identity) }
    function global:Get-Label { [CmdletBinding()] param($Identity) }
}

AfterAll {
    Remove-Item -Path function:global:Get-DlpCompliancePolicy -ErrorAction SilentlyContinue
    Remove-Item -Path function:global:Get-DlpComplianceRule -ErrorAction SilentlyContinue
    Remove-Item -Path function:global:Get-DlpSensitiveInformationType -ErrorAction SilentlyContinue
    Remove-Item -Path function:global:Get-Label -ErrorAction SilentlyContinue
}

Describe 'Get-DlpInventory reference resolution' {
    BeforeEach {
        Mock -ModuleName PurviewDlpExport Get-DlpCompliancePolicy {
            @([PSCustomObject]@{ Name = 'P1' })
        }
        Mock -ModuleName PurviewDlpExport Get-DlpComplianceRule {
            @(
                [PSCustomObject]@{
                    Name             = 'R1'
                    ParentPolicyName = 'P1'
                    ContentContainsSensitiveInformation = @(
                        [PSCustomObject]@{ id = 'sit-1' },
                        [PSCustomObject]@{ id = 'sit-2' }
                    )
                    HasSensitiveInformation = @(
                        [PSCustomObject]@{ id = 'label-1'; type = 'label' }
                    )
                }
            )
        }
        Mock -ModuleName PurviewDlpExport Get-DlpSensitiveInformationType {
            @(
                [PSCustomObject]@{ Id = 'sit-1'; Name = 'Credit Card Number' },
                [PSCustomObject]@{ Id = 'sit-2'; Name = 'AWS Access Key' }
            )
        }
        Mock -ModuleName PurviewDlpExport Get-Label {
            @(
                [PSCustomObject]@{
                    Guid        = 'label-1'
                    ImmutableId = 'label-1'
                    Name        = 'HC'
                    DisplayName = 'Highly Confidential'
                }
            )
        }
    }

    It 'fetches the SIT catalogue once in bulk, not per referenced id' {
        $null = Get-DlpInventory
        Should -Invoke -ModuleName PurviewDlpExport Get-DlpSensitiveInformationType -Times 1 -Exactly
    }

    It 'fetches the label catalogue once in bulk, not per referenced id' {
        $null = Get-DlpInventory
        Should -Invoke -ModuleName PurviewDlpExport Get-Label -Times 1 -Exactly
    }

    It 'resolves referenced SIT names from the catalogue' {
        $inv = Get-DlpInventory
        $byId = @{}
        foreach ($s in $inv.ReferencedSits) { $byId[$s.Id] = $s.Name }
        $byId['sit-1'] | Should -Be 'Credit Card Number'
        $byId['sit-2'] | Should -Be 'AWS Access Key'
    }

    It 'resolves referenced label names to DisplayName' {
        $inv = Get-DlpInventory
        @($inv.ReferencedLabels).Count | Should -Be 1
        $inv.ReferencedLabels[0].Name | Should -Be 'Highly Confidential'
    }

    It 'records a referenced id missing from the catalogue as a true orphan (Name = null)' {
        Mock -ModuleName PurviewDlpExport Get-DlpComplianceRule {
            @(
                [PSCustomObject]@{
                    Name             = 'R1'
                    ParentPolicyName = 'P1'
                    ContentContainsSensitiveInformation = @(
                        [PSCustomObject]@{ id = 'sit-gone' }
                    )
                    HasSensitiveInformation = $null
                }
            )
        }
        $inv = Get-DlpInventory
        @($inv.ReferencedSits).Count | Should -Be 1
        $inv.ReferencedSits[0].Id | Should -Be 'sit-gone'
        $inv.ReferencedSits[0].Name | Should -BeNullOrEmpty
    }

    It 'propagates a SIT catalogue fetch failure instead of silently recording orphans' {
        # A transient failure must abort the run: swallowing it would emit a baseline whose
        # bytes differ from a healthy run, masquerading as a tenant config change.
        Mock -ModuleName PurviewDlpExport Get-DlpSensitiveInformationType { throw 'transient failure' }
        { Get-DlpInventory } | Should -Throw '*transient failure*'
    }

    It 'propagates a label catalogue fetch failure instead of silently recording orphans' {
        Mock -ModuleName PurviewDlpExport Get-Label { throw 'transient failure' }
        { Get-DlpInventory } | Should -Throw '*transient failure*'
    }
}
