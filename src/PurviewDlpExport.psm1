Set-StrictMode -Version Latest

$script:VolatileFields = @(
    'RunspaceId',
    'ETag',
    'WhenCreatedUTC',
    'WhenChangedUTC',
    'ObjectVersion',
    'ImmutableId'
)

function ConvertTo-NormalisedBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Inventory
    )

    $normalised = [PSCustomObject]@{
        Policies         = $Inventory.Policies
        Rules            = $Inventory.Rules
        ReferencedSits   = $Inventory.ReferencedSits
        ReferencedLabels = $Inventory.ReferencedLabels
    }

    [PSCustomObject]@{
        Normalised     = $normalised
        StrippedFields = $script:VolatileFields
    }
}

Export-ModuleMember -Function ConvertTo-NormalisedBaseline
