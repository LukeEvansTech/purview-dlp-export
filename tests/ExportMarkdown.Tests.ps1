BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1'
    Import-Module $modulePath -Force

    $fixturePath = Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json'
    $script:rawInventory = Get-Content $fixturePath -Raw | ConvertFrom-Json
    $script:normalised   = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
}

Describe 'Export-DlpBaselineMarkdown' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-md-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue
    }

    It 'matches the expected.md snapshot byte-for-byte' {
        Export-DlpBaselineMarkdown `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -DateStamp '20260521'

        $actualPath   = Join-Path $script:outDir 'baseline-20260521-acme.md'
        $expectedPath = Join-Path $PSScriptRoot 'fixtures' 'expected.md'

        $actual   = Get-Content $actualPath   -Raw
        $expected = Get-Content $expectedPath -Raw

        $actual | Should -Be $expected
    }

    It 'reports correct counts in the top metadata' {
        Export-DlpBaselineMarkdown `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -DateStamp '20260521'

        $content = Get-Content (Join-Path $script:outDir 'baseline-20260521-acme.md') -Raw

        $expectedPolicyCount = $script:normalised.Normalised.Policies.Count
        $expectedRuleCount   = $script:normalised.Normalised.Rules.Count

        $content | Should -Match "Policies: $expectedPolicyCount"
        $content | Should -Match "Rules: $expectedRuleCount"
    }
}
