@{
    RootModule        = 'PurviewDlpExport.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7d2c5e1a-8b9f-4a31-9c2e-1f3a5b7d9e2c'
    Author            = 'Luke Evans'
    Description       = 'Read-only Purview DLP ruleset baseline export.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-TenantNameFromUpn',
        'Connect-PurviewDlpSession',
        'Get-DlpInventory',
        'ConvertTo-NormalisedBaseline',
        'Export-DlpBaselineJson'
    )
}
