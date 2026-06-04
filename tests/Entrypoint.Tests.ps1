Describe 'Export-PurviewDlp.ps1 emitter wiring' {
    It 'references all three new emitters and no longer calls the retired Markdown export' {
        $script = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-PurviewDlp.ps1') -Raw
        $script | Should -Match 'ConvertTo-DlpView'
        $script | Should -Match 'Export-DlpOverviewMarkdown'
        $script | Should -Match 'Export-DlpDetailMarkdown'
        $script | Should -Match 'Export-DlpMatrixCsv'
        $script | Should -Not -Match 'Export-DlpBaselineMarkdown'
    }

    It 'creates the output directory instead of failing when it does not exist' {
        $script = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-PurviewDlp.ps1') -Raw
        $script | Should -Match 'New-Item -ItemType Directory -Path \$OutDir'
        $script | Should -Not -Match 'throw "OutDir does not exist'
    }

    It 'infers the tenant from the UPN when -Tenant is not supplied' {
        $script = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-PurviewDlp.ps1') -Raw
        $script | Should -Match 'Get-TenantNameFromUpn'
        # -Tenant must no longer be a mandatory parameter
        $script | Should -Not -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$Tenant'
    }
}
