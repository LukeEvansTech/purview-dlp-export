Describe 'PowerShell 5.1 source compatibility' {
    BeforeAll {
        $script:srcDir = Join-Path $PSScriptRoot '..' 'src'
        $script:moduleFiles = Get-ChildItem -Path $script:srcDir -Filter '*.psm1' -Recurse
    }

    It 'has at least one module file to scan' {
        $script:moduleFiles.Count | Should -BeGreaterThan 0
    }

    It 'does not use ConvertFrom-Json -AsHashtable (PS 6+ only) in <Name>' -ForEach @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'src') -Filter '*.psm1' -Recurse |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        (Get-Content $Path -Raw) | Should -Not -Match '-AsHashtable'
    }
}
