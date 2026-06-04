BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
}

Describe 'Get-TenantNameFromUpn' {
    It 'derives the tenant label from an onmicrosoft.com UPN' {
        Get-TenantNameFromUpn -UserPrincipalName 'administrator@codelooks.onmicrosoft.com' | Should -Be 'codelooks'
    }
    It 'matches the onmicrosoft suffix case-insensitively, preserving the label case' {
        Get-TenantNameFromUpn -UserPrincipalName 'admin@Contoso.OnMicrosoft.Com' | Should -Be 'Contoso'
    }
    It 'falls back to the first domain label for a custom (vanity) domain' {
        Get-TenantNameFromUpn -UserPrincipalName 'admin@contoso.com' | Should -Be 'contoso'
    }
    It 'handles a multi-label initial onmicrosoft domain' {
        Get-TenantNameFromUpn -UserPrincipalName 'u@sub.contoso.onmicrosoft.com' | Should -Be 'sub.contoso'
    }
}
