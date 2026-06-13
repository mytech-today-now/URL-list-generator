<#
.SYNOPSIS
    list-gen Module Root - Web Directory URL List Generator

.DESCRIPTION
    Root module file that loads all nested modules and exports public functions.
    This module provides functionality to extract file URLs from web directory listings
    and generate text files containing those URLs.

.NOTES
    Version: 3.1.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Module version (also in manifest)
$script:ModuleVersion = '3.1.0'
$script:ModuleName = 'list-gen'

# Load nested modules (defined in manifest NestedModules)
# They are automatically loaded by the module system

# Export module version for consumers
New-Variable -Name ScriptVersion -Value $script:ModuleVersion -Scope Script -Force
New-Variable -Name ScriptName -Value $script:ModuleName -Scope Script -Force

# Re-export public functions from nested modules for convenience
# (Functions are already exported via manifest FunctionsToExport,
#  but this ensures they're available when dot-sourcing the module file directly)

# Logging functions
if (Get-Command -Name 'Initialize-Log' -ErrorAction SilentlyContinue) {
    Export-ModuleMember -Function 'Initialize-Log', 'Write-Log', 'Write-DebugLog', 'Write-InfoLog', 'Write-WarnLog', 'Write-ErrorLog'
}

# Network functions
if (Get-Command -Name 'Invoke-WebRequestWithRetry' -ErrorAction SilentlyContinue) {
    Export-ModuleMember -Function 'Invoke-WebRequestWithRetry', 'Invoke-HttpClientRequest', 'Set-NetworkConfig', 'Get-NetworkConfig', 'Test-CertificatePin'
}

# URL functions
if (Get-Command -Name 'Normalize-Url' -ErrorAction SilentlyContinue) {
    Export-ModuleMember -Function 'Normalize-Url', 'Test-IsFileUrl', 'Extract-FileUrls', 'Resolve-RelativeUrl', 'Should-IncludeUrl', 'Test-Url', 'Get-UrlFileName'
}

# Input functions
if (Get-Command -Name 'Parse-InputFile' -ErrorAction SilentlyContinue) {
    Export-ModuleMember -Function 'Parse-InputFile', 'Parse-CommandLineEntries', 'Parse-InteractiveInput', 'Validate-AndNormalizeEntries'
}

# Output functions
if (Get-Command -Name 'Get-DefaultOutputDir' -ErrorAction SilentlyContinue) {
    Export-ModuleMember -Function 'Get-DefaultOutputDir', 'Get-DefaultLogDir', 'Test-OutputDirectory', 'New-OutputFilePath', 'Write-UrlListToFile', 'New-ProcessingResult', 'Process-DirectoryEntry'
}

<#
.SYNOPSIS
    Programmatic entry point for list-gen module.

.DESCRIPTION
    Processes directory URLs and generates file URL lists. Can be called
    directly from PowerShell scripts without using the CLI entry point.

.PARAMETER Urls
    Array of directory URLs to process.

.PARAMETER InputFile
    Path to file containing URLs to process.

.PARAMETER OutputDir
    Output directory for generated files. Default: ~/Downloads.

.PARAMETER LogDir
    Log directory. Default: platform-appropriate location.
    Alias: ld

.PARAMETER LogLevel
    Minimum log level. Default: INFO.

.PARAMETER NetworkParams
    Hashtable of network parameters (TimeoutSec, MaxRetries, FollowRedirects, ValidateCertificate, CertificatePins).

.PARAMETER Prefix
    Output filename prefix. Default: 'list-gen'.

.PARAMETER Extension
    Output file extension. Default: '.txt'.

.PARAMETER WhatIf
    Show what would be done without executing.

.PARAMETER Confirm
    Prompt for confirmation before processing each entry.

.OUTPUTS
    Array of processing result objects.

.EXAMPLE
    $results = Invoke-ListGen -Urls @('https://example.com/files/', 'https://example.org/data/')

.EXAMPLE
    $results = Invoke-ListGen -InputFile 'urls.txt' -OutputDir '~/output' -LogLevel DEBUG

.EXAMPLE
    $results = Invoke-ListGen -Urls @('https://example.com/') -WhatIf
#>
function Invoke-ListGen {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(ParameterSetName = 'Urls', Position = 0)]
        [ValidateNotNull()]
        [string[]]$Urls,

        [Parameter(ParameterSetName = 'InputFile', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$InputFile,

        [Parameter()]
        [Alias('o', 'out')]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDir,

        [Parameter()]
        [Alias('ld')]  # Consistent alias with CLI
        [ValidateNotNullOrEmpty()]
        [string]$LogDir,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$LogLevel = 'INFO',

        [Parameter()]
        [ValidateNotNull()]
        [hashtable]$NetworkParams,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Prefix = 'list-gen',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Extension = '.txt',

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [switch]$Confirm
    )

    # Resolve defaults
    if (-not $OutputDir) { $OutputDir = Get-DefaultOutputDir }
    if (-not $LogDir) { $LogDir = Get-DefaultLogDir }

    # Initialize logging
    $logFile = Join-Path $LogDir "list-gen_$(Get-Date -Format 'yyyy-MM').jsonl"
    Initialize-Log -LogPath $logFile -ScriptName $script:ModuleName -ScriptVersion $script:ModuleVersion -MinLevel $LogLevel

    Write-InfoLog -Message "Invoke-ListGen started" -Context @{
        urls           = $Urls
        inputFile      = $InputFile
        outputDir      = $OutputDir
        logDir         = $LogDir
        logLevel       = $LogLevel
        networkParams  = $NetworkParams
        prefix         = $Prefix
        extension      = $Extension
        whatIf         = $WhatIf
        confirm        = $Confirm
        version        = $script:ModuleVersion
    }

    # Validate output directory
    $dirTest = Test-OutputDirectory -Path $OutputDir -CreateIfMissing $true
    if (-not $dirTest.Valid) {
        Write-ErrorLog -Message "Output directory invalid" -Context @{ path = $OutputDir; error = $dirTest.Error }
        throw "Output directory validation failed: $($dirTest.Error)"
    }

    # Gather entries
    $entries = @()

    if ($PSCmdlet.ParameterSetName -eq 'InputFile') {
        Write-DebugLog -Message "Parsing input file" -Context @{ inputFile = $InputFile }
        $entries = Parse-InputFile -FilePath $InputFile
    }
    else {
        Write-DebugLog -Message "Using provided URLs" -Context @{ count = $Urls.Count }
        $entries = $Urls
    }

    if ($entries.Count -eq 0) {
        Write-WarnLog -Message "No entries to process"
        return @()
    }

    # Normalize/validate entries
    $normalizedEntries = Validate-AndNormalizeEntries -Entries $entries -AssumeHttps $true

    if ($normalizedEntries.Count -eq 0) {
        Write-WarnLog -Message "No valid entries after normalization"
        return @()
    }

    Write-InfoLog -Message "Processing entries" -Context @{ total = $normalizedEntries.Count }

    # WhatIf support
    if ($WhatIf) {
        Write-Host "WhatIf: Would process $($normalizedEntries.Count) directory URLs" -ForegroundColor Yellow
        foreach ($entry in $normalizedEntries) {
            Write-Host "  - $($entry.AbsoluteUri)"
        }
        return @()
    }

    # Confirm support
    if ($Confirm) {
        $choice = Read-Host "Process $($normalizedEntries.Count) entries? [Y/N]"
        if ($choice -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            Write-InfoLog -Message "User cancelled operation"
            return @()
        }
    }

    # Process each entry
    $results = @()
    foreach ($entry in $normalizedEntries) {
        if ($PSCmdlet.ShouldProcess($entry.AbsoluteUri, 'Extract file URLs and generate output file')) {
            $result = Process-DirectoryEntry -Entry $entry.AbsoluteUri -OutputDir $OutputDir -NetworkParams $NetworkParams -Prefix $Prefix -Extension $Extension
            $results += $result

            if ($result.Success) {
                Write-InfoLog -Message "Entry processed successfully" -Context @{
                    sourceUrl  = $entry.AbsoluteUri
                    fileCount  = $result.FileCount
                    outputFile = $result.OutputFile
                }
            }
            else {
                Write-ErrorLog -Message "Entry processing failed" -Context @{
                    sourceUrl = $entry.AbsoluteUri
                    error     = $result.Error
                }
            }
        }
    }

    Write-InfoLog -Message "Invoke-ListGen completed" -Context @{
        total      = $results.Count
        successful = ($results | Where-Object { $_.Success }).Count
        failed     = ($results | Where-Object { -not $_.Success }).Count
    }

    return $results
}

# Alias for convenience (exported via manifest AliasesToExport)
Set-Alias -Name list-gen -Value Invoke-ListGen -Scope Global -Force

# Module initialization message (only when imported interactively)
if ($Host.Name -eq 'ConsoleHost' -and -not $PSCommandPath) {
    Write-Verbose "Loaded list-gen module v$script:ModuleVersion"
}