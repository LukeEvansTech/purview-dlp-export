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
    foreach ($prop in $Record.PSObject.Properties) {
        if ($Fields -notcontains $prop.Name) {
            $copy[$prop.Name] = $prop.Value
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
    })
    $strippedRules = @($Inventory.Rules | ForEach-Object {
        Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
    })

    $normalised = [PSCustomObject]@{
        Policies         = $strippedPolicies
        Rules            = $strippedRules
        ReferencedSits   = $Inventory.ReferencedSits
        ReferencedLabels = $Inventory.ReferencedLabels
    }

    [PSCustomObject]@{
        Normalised     = $normalised
        StrippedFields = $script:VolatileFields
    }
}

Export-ModuleMember -Function ConvertTo-NormalisedBaseline
