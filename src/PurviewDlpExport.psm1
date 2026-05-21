Set-StrictMode -Version Latest

$script:VolatileFields = @(
    'RunspaceId',
    'ETag',
    'WhenCreatedUTC',
    'WhenChangedUTC',
    'ObjectVersion',
    'ImmutableId'
)

function Remove-VolatileFields {
    [CmdletBinding()]
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

function ConvertTo-NormalisedBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Inventory
    )

    $strippedPolicies = @($Inventory.Policies | ForEach-Object {
        Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
    } | Sort-Object Name)

    $strippedRules = @($Inventory.Rules | ForEach-Object {
        Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
    } | Sort-Object ParentPolicyName, Name)

    $sortedSits = @($Inventory.ReferencedSits | Sort-Object Name)
    $sortedLabels = @($Inventory.ReferencedLabels | Sort-Object Name)

    $normalised = [PSCustomObject]@{
        Policies         = $strippedPolicies
        Rules            = $strippedRules
        ReferencedSits   = $sortedSits
        ReferencedLabels = $sortedLabels
    }

    [PSCustomObject]@{
        Normalised     = $normalised
        StrippedFields = $script:VolatileFields
    }
}

Export-ModuleMember -Function ConvertTo-NormalisedBaseline
