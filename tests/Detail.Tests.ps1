BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpDetailMarkdown' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-dt-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-detail.md' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') | Should -BeTrue
    }
    It 'renders confidence and instance counts in plain English' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $c = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        $c | Should -Match 'high confidence'
        $c | Should -Match '10\+ instances'
    }
    It 'renders the orphan reference visibly' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw) |
            Should -Match 'orphan id=sit-deleted-orphan-99999'
    }
    It 'is byte-identical across two runs' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-detail.md')
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw) | Should -Be $first
    }
    It 'matches the expected-detail.md snapshot byte-for-byte' {
        Export-DlpDetailMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-detail.md') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-detail.md') -Raw
        $actual | Should -Be $expected
    }
}
