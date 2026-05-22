@{
    ExcludeRules = @(
        # PS 7 standardised on UTF-8 without BOM. The rule exists for legacy
        # PS 5.1 file-encoding compatibility we don't support.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
