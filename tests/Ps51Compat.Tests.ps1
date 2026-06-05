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

    # Windows PowerShell 5.1 reads BOM-less script files as the system ANSI codepage, not
    # UTF-8, so any non-ASCII byte (e.g. an em-dash in a string or comment) is mangled and
    # can break parsing. All PowerShell that 5.1 might parse must be pure ASCII: src/ and
    # scripts/ at runtime, and tests/ for the optional "run Pester on 5.1" verification.
    # (Fixtures under tests/fixtures/ are data, never parsed as script.)
    It 'contains only ASCII bytes in <Name>' -ForEach @(
        @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'src') -Include '*.psm1', '*.psd1' -Recurse
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'scripts') -Include '*.ps1' -Recurse
            Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1'
        ) | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $nonAscii = [System.IO.File]::ReadAllBytes($Path) | Where-Object { $_ -gt 127 }
        @($nonAscii).Count | Should -Be 0
    }
}
