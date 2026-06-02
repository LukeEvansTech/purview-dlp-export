BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpRender.psm1') -Force
    $raw  = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json') -Raw | ConvertFrom-Json
    $norm = ConvertTo-NormalisedBaseline -Inventory $raw
    $script:view = ConvertTo-DlpView -Normalised $norm.Normalised
}

Describe 'Export-DlpMatrixCsv' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-csv-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes baseline-<date>-<tenant>-matrix.csv' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        Test-Path (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') | Should -BeTrue
    }
    It 'has a header plus one row per rule (5 rules -> 6 lines)' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $lines = (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw) -split "`n" |
            Where-Object { $_ -ne '' }
        $lines.Count | Should -Be 6
    }
    It 'has the agreed columns in the header' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $header = ((Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv')) | Select-Object -First 1)
        $header | Should -Be 'Policy,Rule,Workloads,Enabled,Mode,Priority,Detects,Conditions,Actions,Exceptions'
    }
    It 'is byte-identical across two runs' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw
        Remove-Item (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv')
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw) | Should -Be $first
    }
    It 'matches the expected-matrix.csv snapshot byte-for-byte' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $actual   = Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw
        $expected = Get-Content (Join-Path $PSScriptRoot 'fixtures' 'expected-matrix.csv') -Raw
        $actual | Should -Be $expected
    }
}
