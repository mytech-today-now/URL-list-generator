<#
.SYNOPSIS
    Output handling utilities for list-gen - file generation, naming, deduplication.

.DESCRIPTION
    Manages output file creation with collision-resistant naming,
    directory validation, and structured result objects for pipeline consumption.

.NOTES
    Version: 3.0.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Default output directory resolution (cross-platform)
function Get-DefaultOutputDir {
    # Priority: XDG_DOWNLOAD_DIR > ~/Downloads > %USERPROFILE%\Downloads > $env:TEMP
    if ($env:XDG_DOWNLOAD_DIR -and (Test-Path $env:XDG_DOWNLOAD_DIR)) {
        return $env:XDG_DOWNLOAD_DIR
    }

    $userHome = $env:HOME
    if (-not $userHome) { $userHome = $env:USERPROFILE }

    $downloads = Join-Path $userHome 'Downloads'
    if (Test-Path $downloads) {
        return $downloads
    }

    # Fallback to temp
    return $env:TEMP
}

# Default log directory resolution (cross-platform)
function Get-DefaultLogDir {
    # Priority: XDG_STATE_HOME > XDG_DATA_HOME > ~/.local/state > ~/Library/Logs (macOS) > %LOCALAPPDATA% (Windows) > $env:TEMP
    if ($env:XDG_STATE_HOME) {
        return Join-Path $env:XDG_STATE_HOME 'list-gen/logs'
    }
    if ($env:XDG_DATA_HOME) {
        return Join-Path $env:XDG_DATA_HOME 'list-gen/logs'
    }

    $userHome = $env:HOME
    if (-not $userHome) { $userHome = $env:USERPROFILE }

    if ($IsMacOS) {
        return Join-Path $userHome 'Library/Logs/list-gen'
    }
    if ($IsWindows) {
        $localAppData = $env:LOCALAPPDATA
        if ($localAppData) {
            return Join-Path $localAppData 'list-gen/logs'
        }
    }

    # Linux/Unix default
    return Join-Path $userHome '.local/state/list-gen/logs'
}

<#
.SYNOPSIS
    Validates that a directory exists and is writable.

.PARAMETER Path
    Directory path to validate.

.PARAMETER CreateIfMissing
    Create directory if it doesn't exist. Default: true.

.RETURNS
    PSCustomObject with Valid (bool), Path (resolved path), Error (string).
#>
function Test-OutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter()]
        [bool]$CreateIfMissing = $true
    )

    $result = [PSCustomObject]@{
        Valid = $false
        Path  = $null
        Error = $null
    }

    try {
        $fullPath = Resolve-Path -Path $Path -ErrorAction SilentlyContinue

        if (-not $fullPath) {
            if ($CreateIfMissing) {
                $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
                $fullPath = Resolve-Path -Path $Path -ErrorAction Stop
            }
            else {
                $result.Error = "Directory does not exist: $Path"
                return $result
            }
        }

        $resolvedPath = $fullPath.ProviderPath

        # Test writability by creating a temp file
        $testFile = Join-Path $resolvedPath ".write_test_$([Guid]::NewGuid()).tmp"
        try {
            Set-Content -Path $testFile -Value "test" -ErrorAction Stop
            Remove-Item -Path $testFile -Force -ErrorAction Stop
        }
        catch {
            $result.Error = "Directory is not writable: $($_.Exception.Message)"
            return $result
        }

        $result.Valid = $true
        $result.Path  = $resolvedPath
    }
    catch {
        $result.Error = "Failed to validate directory: $($_.Exception.Message)"
    }

    return $result
}

<#
.SYNOPSIS
    Generates a collision-resistant output filename.

.DESCRIPTION
    Creates a filename based on:
    - Script name prefix
    - Sanitized source identifier (domain/path)
    - ISO-8601 timestamp with milliseconds
    - Optional hash suffix for guaranteed uniqueness

.PARAMETER SourceIdentifier
    String to derive filename from (e.g., source URL).

.PARAMETER OutputDir
    Output directory (used to check for collisions).

.PARAMETER Prefix
    Filename prefix. Default: 'list-gen'.

.PARAMETER Extension
    File extension. Default: '.txt'.

.PARAMETER UseHash
    Append short hash for guaranteed uniqueness. Default: true.

.RETURNS
    Full output file path string.
#>
function New-OutputFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourceIdentifier,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputDir,

        [Parameter()]
        [string]$Prefix = 'list-gen',

        [Parameter()]
        [string]$Extension = '.txt',

        [Parameter()]
        [bool]$UseHash = $true
    )

    # Sanitize source identifier for filename
    $safeName = $SourceIdentifier
    # Remove scheme
    $safeName = $safeName -replace '^https?://', ''
    # Remove query and fragment
    $safeName = $safeName -split '\?|#' | Select-Object -First 1
    # Replace non-alphanumeric with underscore
    $safeName = $safeName -replace '[^a-zA-Z0-9._-]', '_'
    # Collapse multiple underscores
    $safeName = $safeName -replace '_+', '_'
    # Trim to reasonable length
    $maxNameLen = 60
    if ($safeName.Length -gt $maxNameLen) {
        $safeName = $safeName.Substring(0, $maxNameLen).TrimEnd('_')
    }
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'unknown'
    }

    # Timestamp with milliseconds for near-uniqueness
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"

    # Base filename
    $baseName = "${Prefix}-${safeName}-${timestamp}"

    # Add hash for guaranteed uniqueness if requested
    if ($UseHash) {
        $hashInput = "${SourceIdentifier}${timestamp}$([Guid]::NewGuid())"
        $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashInput))
        $shortHash = [Convert]::ToBase64String($hashBytes)[0..7] -join '' -replace '[/+=]', ''
        $baseName += "-$shortHash"
    }

    $fileName = "$baseName$Extension"
    $fullPath = Join-Path $OutputDir $fileName

    # Final collision check (extremely unlikely with hash, but safe)
    $counter = 0
    while (Test-Path $fullPath) {
        $counter++
        $fileName = "${baseName}_$counter$Extension"
        $fullPath = Join-Path $OutputDir $fileName
        if ($counter -gt 100) {
            throw "Unable to generate unique filename after 100 attempts"
        }
    }

    return $fullPath
}

<#
.SYNOPSIS
    Writes URL list to output file.

.DESCRIPTION
    Writes array of URLs to a text file, one per line, with UTF-8 encoding.
    Validates directory writability first.

.PARAMETER Urls
    Array of URL strings to write.

.PARAMETER OutputPath
    Full path to output file.

.PARAMETER Encoding
    File encoding. Default: UTF8NoBOM.

.OUTPUTS
    PSCustomObject with result info (Success, Path, Count, Error).
#>
function Write-UrlList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string[]]$Urls,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputPath,

        [Parameter()]
        [ValidateSet('UTF8', 'UTF8NoBOM', 'UTF7', 'UTF32', 'ASCII', 'Unicode', 'BigEndianUnicode')]
        [string]$Encoding = 'UTF8NoBOM'
    )

    begin {
        $writeCount = 0
    }

    process {
        # We receive URLs via pipeline, but need all for single write
        # Collect in variable - this is a limitation of the design
        # Better: accept array directly in most cases
    }

    end {
        # This function is designed for array input, not pipeline
        # The process block won't work as expected for this pattern
        # Caller should pass array directly
    }
}

# Better design: main function accepts array
function Write-UrlListToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Urls,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputPath,

        [Parameter()]
        [ValidateSet('UTF8', 'UTF8NoBOM', 'UTF7', 'UTF32', 'ASCII', 'Unicode', 'BigEndianUnicode')]
        [string]$Encoding = 'UTF8NoBOM'
    )

    $result = [PSCustomObject]@{
        Success = $false
        Path    = $OutputPath
        Count   = 0
        Error   = $null
    }

    if ($Urls.Count -eq 0) {
        $result.Error = "No URLs to write"
        Write-WarnLog -Message "Write-UrlListToFile called with empty URL array" -Context @{ outputPath = $OutputPath }
        return $result
    }

    # Validate parent directory
    $dir = Split-Path $OutputPath -Parent
    $dirTest = Test-OutputDirectory -Path $dir -CreateIfMissing $true
    if (-not $dirTest.Valid) {
        $result.Error = $dirTest.Error
        Write-ErrorLog -Message "Output directory validation failed" -Context @{ outputPath = $OutputPath; error = $dirTest.Error }
        return $result
    }

    try {
        # Write all URLs, one per line
        $Urls | ForEach-Object { $_ } | Set-Content -Path $OutputPath -Encoding $Encoding -ErrorAction Stop

        $result.Success = $true
        $result.Count   = $Urls.Count

        Write-InfoLog -Message "Wrote URL list to file" -Context @{
            outputPath = $OutputPath
            urlCount   = $Urls.Count
            encoding   = $Encoding
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-ErrorLog -Message "Failed to write output file" -Context @{
            outputPath = $OutputPath
            error      = $_.Exception.Message
        } -Exception $_
    }

    return $result
}

<#
.SYNOPSIS
    Creates a structured result object for pipeline output.

.DESCRIPTION
    Produces a consistent PSCustomObject representing the outcome of processing
    a single directory URL. Suitable for pipeline consumption and further processing.

.PARAMETER SourceUrl
    Original source URL that was processed.

.PARAMETER NormalizedUrl
    The normalized directory URI (System.Uri).

.PARAMETER FileUrls
    Array of extracted file URL strings.

.PARAMETER OutputFile
    Path to the generated output file (or $null if no files/failed).

.PARAMETER Success
    Whether processing succeeded.

.PARAMETER Error
    Error message if failed.

.OUTPUTS
    PSCustomObject with all properties.
#>
function New-ProcessingResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceUrl,

        [Parameter()]
        [System.Uri]$NormalizedUrl,

        [Parameter()]
        [string[]]$FileUrls = @(),

        [Parameter()]
        [string]$OutputFile,

        [Parameter()]
        [bool]$Success = $true,

        [Parameter()]
        [string]$ErrorMessage

    )

    $result = [PSCustomObject]@{
        SourceUrl     = $SourceUrl
        NormalizedUrl = if ($NormalizedUrl) { $NormalizedUrl.AbsoluteUri } else { $null }
        FileCount     = $FileUrls.Count
        FileUrls      = $FileUrls
        OutputFile    = $OutputFile
        Success       = $Success
        Error         = $ErrorMessage
        Timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffzzz")
    }

    return $result
}

<#
.SYNOPSIS
    Processes a single directory entry end-to-end.

.DESCRIPTION
    High-level function that:
    1. Normalizes the input URL
    2. Extracts file URLs from the directory listing
    3. Generates output file path
    4. Writes the URL list to file
    5. Returns structured result object

.PARAMETER Entry
    Input URL or directory path.

.PARAMETER OutputDir
    Directory for output files.

.PARAMETER NetworkParams
    Hashtable of network parameters (TimeoutSec, MaxRetries, FollowRedirects, ValidateCertificate, CertificatePins).

.PARAMETER Prefix
    Output filename prefix.

.PARAMETER Extension
    Output file extension.

.OUTPUTS
    Processing result PSCustomObject (from New-ProcessingResult).
#>
function Process-DirectoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Entry,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputDir,

        [Parameter()]
        [hashtable]$NetworkParams,

        [Parameter()]
        [string]$Prefix = 'list-gen',

        [Parameter()]
        [string]$Extension = '.txt'
    )

    Write-DebugLog -Message "Processing directory entry" -Context @{ entry = $Entry; outputDir = $OutputDir }

    # Default network params
    $netParams = @{
        TimeoutSec          = 60
        MaxRetries          = 3
        FollowRedirects     = $true
        ValidateCertificate = $true
        CertificatePins     = @()
    }
    if ($NetworkParams) {
        foreach ($key in $NetworkParams.Keys) {
            if ($netParams.ContainsKey($key)) {
                $netParams[$key] = $NetworkParams[$key]
            }
        }
    }

    # Step 1: Normalize URL
    $normalizedUri = Normalize-Url -Url $Entry -TreatAsDirectory
    if (-not $normalizedUri) {
        return New-ProcessingResult -SourceUrl $Entry -Success $false -ErrorMessage "Invalid URL after normalization"
    }

    # Step 2: Extract file URLs
    try {
        $fileUrls = Extract-FileUrls -DirectoryUrl $normalizedUri.AbsoluteUri `
            -TimeoutSec $netParams.TimeoutSec `
            -MaxRetries $netParams.MaxRetries `
            -FollowRedirects $netParams.FollowRedirects `
            -ValidateCertificate $netParams.ValidateCertificate `
            -CertificatePins $netParams.CertificatePins
    }
    catch {
        return New-ProcessingResult -SourceUrl $Entry -NormalizedUrl $normalizedUri -Success $false -ErrorMessage $_.Exception.Message
    }

    if ($fileUrls.Count -eq 0) {
        Write-WarnLog -Message "No files found in directory listing" -Context @{ directoryUrl = $normalizedUri.AbsoluteUri }
        return New-ProcessingResult -SourceUrl $Entry -NormalizedUrl $normalizedUri -FileUrls @() -Success $true
    }

    # Step 3: Generate output file path
    $outputFile = New-OutputFilePath -SourceIdentifier $Entry -OutputDir $OutputDir -Prefix $Prefix -Extension $Extension -UseHash $true

    # Step 4: Write URL list
    $writeResult = Write-UrlListToFile -Urls $fileUrls -OutputPath $outputFile -Encoding 'UTF8NoBOM'

    if (-not $writeResult.Success) {
        return New-ProcessingResult -SourceUrl $Entry -NormalizedUrl $normalizedUri -FileUrls $fileUrls -Success $false -ErrorMessage $writeResult.Error
    }

    # Step 5: Return success result
    return New-ProcessingResult -SourceUrl $Entry -NormalizedUrl $normalizedUri -FileUrls $fileUrls -OutputFile $writeResult.Path -Success $true
}

Export-ModuleMember -Function @(
    'Get-DefaultOutputDir'
    'Get-DefaultLogDir'
    'Test-OutputDirectory'
    'New-OutputFilePath'
    'Write-UrlListToFile'
    'New-ProcessingResult'
    'Process-DirectoryEntry'
)