Describe 'Export-PurviewDlp.ps1 emitter wiring' {
    It 'references all three new emitters and no longer calls the retired Markdown export' {
        $script = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-PurviewDlp.ps1') -Raw
        $script | Should -Match 'ConvertTo-DlpView'
        $script | Should -Match 'Export-DlpOverviewMarkdown'
        $script | Should -Match 'Export-DlpDetailMarkdown'
        $script | Should -Match 'Export-DlpMatrixCsv'
        $script | Should -Not -Match 'Export-DlpBaselineMarkdown'
    }
}
