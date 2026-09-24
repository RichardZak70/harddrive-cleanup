# PSScriptAnalyzer settings for this repository. CI runs every rule at every
# severity except the three below, each excluded for a stated reason.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # The coloured, redrawn console board IS the program's interface, and
        # Write-Host is the only way to colour it. Nothing is written to the
        # output pipeline, so nothing downstream expects objects.
        'PSAvoidUsingWriteHost',

        # Flagged on New-Task, Set-TaskDone, Update-Progress and similar,
        # which change only in-memory task state or the console. Every change
        # to the disk goes through Invoke-FileClean, Invoke-WuCacheTask or
        # Invoke-DismTask, all gated by the -DryRun switch.
        'PSUseShouldProcessForStateChangingFunctions',

        # -DryRun, -NoElevate, -NoWait and -SystemOnly are read inside the
        # script's functions through script scope, which this rule cannot see.
        'PSReviewUnusedParameter'
    )
}
