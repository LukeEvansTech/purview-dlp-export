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

function Add-OrphanAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Rule,
        [Parameter(Mandatory)]
        [string[]] $KnownSitIds,
        [Parameter(Mandatory)]
        [string[]] $KnownLabelIds
    )

    $copy = [ordered]@{}
    foreach ($name in ($Rule.PSObject.Properties.Name | Sort-Object)) {
        $value = $Rule.PSObject.Properties[$name].Value

        if ($name -eq 'ContentContainsSensitiveInformation' -and $null -ne $value) {
            $value = @($value | ForEach-Object {
                $raw = [ordered]@{}
                foreach ($p in ($_.PSObject.Properties.Name | Sort-Object)) {
                    $raw[$p] = $_.PSObject.Properties[$p].Value
                }
                $raw['Orphan'] = ($KnownSitIds -notcontains $_.id)
                $ref = [ordered]@{}
                foreach ($k in ($raw.Keys | Sort-Object)) { $ref[$k] = $raw[$k] }
                [PSCustomObject]$ref
            })
        }
        elseif ($name -eq 'HasSensitiveInformation' -and $null -ne $value) {
            $value = @($value | ForEach-Object {
                $raw = [ordered]@{}
                foreach ($p in ($_.PSObject.Properties.Name | Sort-Object)) {
                    $raw[$p] = $_.PSObject.Properties[$p].Value
                }
                if ($_.type -eq 'label') {
                    $raw['Orphan'] = ($KnownLabelIds -notcontains $_.id)
                } else {
                    $raw['Orphan'] = ($KnownSitIds -notcontains $_.id)
                }
                $ref = [ordered]@{}
                foreach ($k in ($raw.Keys | Sort-Object)) { $ref[$k] = $raw[$k] }
                [PSCustomObject]$ref
            })
        }

        $copy[$name] = $value
    }
    [PSCustomObject]$copy
}

function ConvertTo-NormalisedBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Inventory
    )

    $knownSitIds   = @($Inventory.ReferencedSits   | ForEach-Object { $_.Id })
    $knownLabelIds = @($Inventory.ReferencedLabels | ForEach-Object { $_.Id })

    $strippedPolicies = @($Inventory.Policies | ForEach-Object {
        Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
    } | Sort-Object Name)

    $strippedRules = @($Inventory.Rules | ForEach-Object {
        $stripped = Remove-VolatileFields -Record $_ -Fields $script:VolatileFields
        Add-OrphanAnnotation -Rule $stripped `
            -KnownSitIds $knownSitIds `
            -KnownLabelIds $knownLabelIds
    } | Sort-Object ParentPolicyName, Name)

    $sortedSits   = @($Inventory.ReferencedSits   | Sort-Object Name)
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

function Export-DlpBaselineJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Normalised,
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [string] $Tenant,
        [Parameter(Mandatory)] [string[]] $StrippedFields,
        [Parameter(Mandatory)] [string] $DateStamp,
        [Parameter(Mandatory)] [string] $RunnerUpn
    )

    if (-not (Test-Path $OutDir)) {
        throw "OutDir does not exist: $OutDir"
    }

    $jsonPath = Join-Path $OutDir "baseline-$DateStamp-$Tenant.json"
    $metaPath = Join-Path $OutDir "baseline-$DateStamp-$Tenant.meta.json"

    $jsonBody = $Normalised | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, $jsonBody, $utf8NoBom)

    $meta = [PSCustomObject]@{
        Tenant              = $Tenant
        RunnerUpn           = $RunnerUpn
        ExtractTimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        StrippedFields      = $StrippedFields
        ToolVersion         = (Get-Module PurviewDlpExport).Version.ToString()
    }
    $metaBody = $meta | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($metaPath, $metaBody, $utf8NoBom)

    [PSCustomObject]@{
        JsonPath = $jsonPath
        MetaPath = $metaPath
    }
}

Export-ModuleMember -Function ConvertTo-NormalisedBaseline, Export-DlpBaselineJson
