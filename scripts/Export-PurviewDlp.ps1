#!/usr/bin/env powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UserPrincipalName,
    # Optional: a short label used only in output filenames. When omitted it is inferred
    # from the UPN domain (e.g. admin@codelooks.onmicrosoft.com -> codelooks).
    [string] $Tenant,
    [string] $OutDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    # Pre-flight
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PowerShell 5.1 or later required. Current: $($PSVersionTable.PSVersion)"
    }
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement |
              Where-Object { $_.Version -ge [version]'3.0.0' })) {
        throw "ExchangeOnlineManagement >= 3.0 required. Install: Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser"
    }
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        Write-Host "Created output directory: $OutDir"
    }

    # Use [IO.Path]::Combine, not 3-arg Join-Path: the third positional arg binds to
    # -AdditionalChildPath, which is PowerShell 6+ only and throws on the WinPS 5.1 target.
    $srcDir     = [System.IO.Path]::Combine($PSScriptRoot, '..', 'src')
    $modulePath = [System.IO.Path]::Combine($srcDir, 'PurviewDlpExport.psd1')
    Import-Module $modulePath -Force
    $renderPath = [System.IO.Path]::Combine($srcDir, 'PurviewDlpRender.psm1')
    Import-Module $renderPath -Force

    # Infer the tenant label from the UPN domain when not supplied explicitly.
    if ([string]::IsNullOrWhiteSpace($Tenant)) {
        $Tenant = Get-TenantNameFromUpn -UserPrincipalName $UserPrincipalName
        if ([string]::IsNullOrWhiteSpace($Tenant)) {
            throw "Could not infer a tenant name from '$UserPrincipalName'. Pass -Tenant explicitly."
        }
        Write-Host "Tenant (inferred from UPN): $Tenant"
    }

    # Connect
    Write-Host "Connecting to Purview as $UserPrincipalName..."
    Connect-PurviewDlpSession -UserPrincipalName $UserPrincipalName

    # Fetch
    Write-Host "Fetching DLP inventory..."
    $inventory = Get-DlpInventory

    Write-Host ("  policies: {0}, rules: {1}, referenced SITs: {2}, referenced labels: {3}" -f `
        $inventory.Policies.Count, `
        $inventory.Rules.Count, `
        $inventory.ReferencedSits.Count, `
        $inventory.ReferencedLabels.Count)

    # Normalise (pure)
    $normResult = ConvertTo-NormalisedBaseline -Inventory $inventory

    # Emit
    # InvariantCulture: the default culture's calendar leaks into 'yyyy' (e.g. Buddhist-era
    # 2569 on th-TH boxes), changing every output filename.
    $dateStamp = (Get-Date).ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
    $jsonOut = Export-DlpBaselineJson `
        -Normalised $normResult.Normalised `
        -OutDir $OutDir `
        -Tenant $Tenant `
        -StrippedFields $normResult.StrippedFields `
        -DateStamp $dateStamp `
        -RunnerUpn $UserPrincipalName

    $view = ConvertTo-DlpView -Normalised $normResult.Normalised

    $overviewOut = Export-DlpOverviewMarkdown -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp
    $detailOut   = Export-DlpDetailMarkdown   -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp
    $matrixOut   = Export-DlpMatrixCsv        -View $view -OutDir $OutDir -Tenant $Tenant -DateStamp $dateStamp

    Write-Host "Wrote:"
    Write-Host "  $($jsonOut.JsonPath)"
    Write-Host "  $($jsonOut.MetaPath)"
    Write-Host "  $($overviewOut.OverviewPath)"
    Write-Host "  $($detailOut.DetailPath)"
    Write-Host "  $($matrixOut.MatrixPath)"
}
catch {
    Write-Error "Export failed: $($_.Exception.Message)"
    exit 1
}
