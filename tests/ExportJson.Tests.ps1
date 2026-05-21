BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'PurviewDlpExport.psd1'
    Import-Module $modulePath -Force

    $fixturePath = Join-Path $PSScriptRoot 'fixtures' 'raw-purview-sample.json'
    $script:rawInventory = Get-Content $fixturePath -Raw | ConvertFrom-Json
    $script:normalised   = ConvertTo-NormalisedBaseline -Inventory $script:rawInventory
}

Describe 'Export-DlpBaselineJson' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue
    }

    It 'writes baseline JSON and meta JSON to OutDir' {
        Export-DlpBaselineJson `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -StrippedFields $script:normalised.StrippedFields `
            -DateStamp '20260521' `
            -RunnerUpn 'admin@acme.onmicrosoft.com'

        $jsonPath = Join-Path $script:outDir 'baseline-20260521-acme.json'
        $metaPath = Join-Path $script:outDir 'baseline-20260521-acme.meta.json'
        Test-Path $jsonPath | Should -BeTrue
        Test-Path $metaPath | Should -BeTrue
    }

    It 'writes UTF-8 without BOM' {
        Export-DlpBaselineJson `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -StrippedFields $script:normalised.StrippedFields `
            -DateStamp '20260521' `
            -RunnerUpn 'admin@acme.onmicrosoft.com'

        $jsonPath = Join-Path $script:outDir 'baseline-20260521-acme.json'
        $bytes = [System.IO.File]::ReadAllBytes($jsonPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'produces byte-identical body on two runs with the same input' {
        Export-DlpBaselineJson `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -StrippedFields $script:normalised.StrippedFields `
            -DateStamp '20260521' `
            -RunnerUpn 'admin@acme.onmicrosoft.com'
        $first = Get-Content (Join-Path $script:outDir 'baseline-20260521-acme.json') -Raw

        Remove-Item (Join-Path $script:outDir 'baseline-20260521-acme.json')

        Export-DlpBaselineJson `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -StrippedFields $script:normalised.StrippedFields `
            -DateStamp '20260521' `
            -RunnerUpn 'admin@acme.onmicrosoft.com'
        $second = Get-Content (Join-Path $script:outDir 'baseline-20260521-acme.json') -Raw

        $second | Should -Be $first
    }

    It 'records StrippedFields, Tenant, and RunnerUpn in the meta sidecar' {
        Export-DlpBaselineJson `
            -Normalised $script:normalised.Normalised `
            -OutDir $script:outDir `
            -Tenant 'acme' `
            -StrippedFields $script:normalised.StrippedFields `
            -DateStamp '20260521' `
            -RunnerUpn 'admin@acme.onmicrosoft.com'

        $metaPath = Join-Path $script:outDir 'baseline-20260521-acme.meta.json'
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json

        $meta.Tenant    | Should -Be 'acme'
        $meta.RunnerUpn | Should -Be 'admin@acme.onmicrosoft.com'
        $meta.StrippedFields | Sort-Object | Should -Be ($script:normalised.StrippedFields | Sort-Object)
        $meta.ExtractTimestampUtc | Should -Not -BeNullOrEmpty
    }
}
