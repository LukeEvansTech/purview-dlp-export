BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpOverviewMarkdown' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-ov-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-overview.md' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') | Should -BeTrue
    }
    It 'contains a table row per policy with its workloads' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $c = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        $c | Should -Match 'Block Credential Leakage'
        $c | Should -Match 'Exchange, SharePoint, OneDrive'
    }
    It 'writes UTF-8 without BOM' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:outDir 'baseline-20260601-acme-overview.md'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
    It 'is byte-identical across two runs' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-overview.md')
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw) | Should -Be $first
    }
    It 'matches the expected-overview.md snapshot byte-for-byte' {
        Export-DlpOverviewMarkdown -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-overview.md') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-overview.md') -Raw
        $actual | Should -Be $expected
    }
}
