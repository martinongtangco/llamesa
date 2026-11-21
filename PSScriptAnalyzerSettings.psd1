# PSScriptAnalyzer settings for client/llamesa.ps1 (used by CI).
# llamesa.ps1 is a single-file interactive terminal app, not a module, so the
# cmdlet-design rules below don't apply.
@{
    ExcludeRules = @(
        # Console UI: Write-Host is the intended output channel.
        'PSAvoidUsingWriteHost'
        # Internal helpers (Cmd-*, Draw-Screen, ...) are never exported as cmdlets.
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        # Script is #Requires -Version 7.0; pwsh reads BOM-less UTF-8 correctly.
        'PSUseBOMForUnicodeEncodedFile'
        # Empty catches are deliberate best-effort cleanup/logging (Dispose, Close,
        # optional parsing); there is nothing useful to report.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
