@{
    ExcludeRules = @(
        # We intentionally write UTF-8 without BOM on all platforms.
        'PSUseBOMForUnicodeEncodedFile'
        # Information-level style suggestion. The test suite uses positional Join-Path
        # ($PSScriptRoot '..' 'src' ...) throughout, consistent with the existing tests;
        # not worth rewriting every call site. Real PS 5.1 syntax/cmdlet incompatibilities
        # are still caught by PSUseCompatibleSyntax / PSUseCompatibleCmdlets above.
        'PSAvoidUsingPositionalParameters'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCmdlets = @{
            compatibility = @(
                'desktop-5.1.14393.206-windows',
                'core-6.1.0-windows'
            )
        }
    }
}
