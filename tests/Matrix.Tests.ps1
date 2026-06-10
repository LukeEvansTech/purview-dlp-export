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
    It 'writes UTF-8 without BOM' {
        Export-DlpMatrixCsv -View $script:view -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}

Describe 'Export-DlpMatrixCsv surfaces unattached rules' {
    BeforeEach {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-csv-ua-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:outDir | Out-Null

        $policy     = [PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true; Priority = 0; Workload = 'Exchange' }
        $attached   = [PSCustomObject]@{ Name = 'R1'; ParentPolicyName = 'P'; Mode = 'Enable'; Priority = 0 }
        $unattached = [PSCustomObject]@{ Name = 'Ghost Rule'; ParentPolicyName = 'Deleted Policy'; Mode = 'Enable'; Priority = 0 }
        $norm = [PSCustomObject]@{ Policies = @($policy); Rules = @($attached, $unattached); ReferencedSits = @(); ReferencedLabels = @() }
        $script:ghostView = ConvertTo-DlpView -Normalised $norm
    }
    AfterEach { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'emits a row for the unattached rule with an explicit marker in the Policy column' {
        Export-DlpMatrixCsv -View $script:ghostView -OutDir $script:outDir -Tenant 'acme' -DateStamp '20260601'
        $lines = (Get-Content (Join-Path $script:outDir 'baseline-20260601-acme-matrix.csv') -Raw) -split "`n" |
            Where-Object { $_ -ne '' }
        $lines.Count | Should -Be 3
        $ghostRow = $lines | Where-Object { $_ -match 'Ghost Rule' }
        $ghostRow | Should -Not -BeNullOrEmpty
        $ghostRow | Should -Match '<unattached: Deleted Policy>'
    }
}

Describe 'ConvertTo-CsvField' {
    It 'wraps a plain value in double quotes' {
        InModuleScope PurviewDlpRender {
            ConvertTo-CsvField 'abc' | Should -Be '"abc"'
        }
    }
    It 'returns empty quoted field for null' {
        InModuleScope PurviewDlpRender {
            ConvertTo-CsvField $null | Should -Be '""'
        }
    }
    It 'doubles embedded double-quotes' {
        InModuleScope PurviewDlpRender {
            ConvertTo-CsvField 'a"b' | Should -Be '"a""b"'
        }
    }
    It 'keeps a comma-containing value as one quoted field' {
        InModuleScope PurviewDlpRender {
            ConvertTo-CsvField 'a,b' | Should -Be '"a,b"'
        }
    }
}

Describe 'regression: multi-line free text stays one CSV row and one Markdown line' {
    BeforeAll {
        $normInput = [PSCustomObject]@{
            Policies = @(
                [PSCustomObject]@{
                    Name     = 'Multiline Policy'
                    Mode     = 'Enable'
                    Enabled  = $true
                    Priority = 0
                    Workload = 'Exchange'
                    Comment  = "Policy line one`nPolicy line two"
                }
            )
            Rules = @(
                [PSCustomObject]@{
                    Name                    = 'Multiline Rule'
                    ParentPolicyName        = 'Multiline Policy'
                    Mode                    = 'Enable'
                    Priority                = 0
                    BlockAccess             = $true
                    NotifyPolicyTipCustomText = "First line`nSecond line"
                    Comment                 = "Rule comment line one`nRule comment line two"
                }
            )
            ReferencedSits   = @()
            ReferencedLabels = @()
        }
        $script:mlView = ConvertTo-DlpView -Normalised $normInput
    }

    It 'Actions joined string contains no newlines' {
        $actions = ($script:mlView.Policies[0].Rules[0].Actions -join '; ')
        $actions | Should -Not -Match '[\r\n]'
    }
    It 'rule Comment contains no newlines' {
        $script:mlView.Policies[0].Rules[0].Comment | Should -Not -Match '[\r\n]'
    }
    It 'CSV output has exactly 2 non-empty lines (1 header + 1 data row)' {
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pde-ml-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $outDir | Out-Null
        try {
            Export-DlpMatrixCsv -View $script:mlView -OutDir $outDir -Tenant 'test' -DateStamp '20260601'
            $raw   = Get-Content (Join-Path $outDir 'baseline-20260601-test-matrix.csv') -Raw
            $lines = $raw -split "`n" | Where-Object { $_ -ne '' }
            $lines.Count | Should -Be 2
        } finally {
            Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue
        }
    }
}
