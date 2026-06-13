<#
.SYNOPSIS
    Input parsing utilities for list-gen - file, command-line, and interactive input.

.DESCRIPTION
    Handles multiple input sources with proper validation:
    - Text files (.txt, .md, .rtf) with delimiter-separated URLs
    - JSON files (arrays, objects with URL properties)
    - Command-line arguments (URLs and file paths)
    - Interactive multi-line input

.NOTES
    Version: 3.0.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Supported input file extensions
$script:SupportedExtensions = @('.txt', '.md', '.rtf', '.json')

# Separator patterns for text-based files (spaces, commas, newlines, tabs)
$script:SeparatorRegex = '[\s,]+'

# Common URL property names in JSON objects
$script:JsonUrlProperties = @(
    'url', 'Url', 'URL',
    'link', 'Link', 'href', 'Href',
    'path', 'Path', 'uri', 'Uri', 'URI',
    'downloadUrl', 'download_url', 'fileUrl', 'file_url'
)

<#
.SYNOPSIS
    Parses an input file and extracts URL entries.

.DESCRIPTION
    Supports multiple formats:
    - .txt, .md, .rtf: Delimiter-separated (spaces, commas, newlines)
    - .json: Array of strings, single string, or objects with URL properties

.PARAMETER FilePath
    Path to the input file.

.PARAMETER Encoding
    File encoding. Default: UTF8.

.OUTPUTS
    Array of URL strings extracted from the file.

.EXAMPLE
    $urls = Parse-InputFile -FilePath 'urls.txt'

.EXAMPLE
    $urls = Parse-InputFile -FilePath 'data.json'
#>
function Parse-InputFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [ValidateSet('UTF8', 'UTF7', 'UTF32', 'ASCII', 'Unicode', 'BigEndianUnicode', 'Default')]
        [string]$Encoding = 'UTF8'
    )

    process {
        # Resolve full path
        $fullPath = Resolve-Path -Path $FilePath -ErrorAction Stop | Select-Object -ExpandProperty ProviderPath
        $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()

        Write-DebugLog -Message "Parsing input file" -Context @{ filePath = $fullPath; extension = $extension }

        # Validate extension
        if ($extension -notin $script:SupportedExtensions) {
            $errorMsg = "Unsupported file extension: $extension. Supported: $($script:SupportedExtensions -join ', ')"
            Write-ErrorLog -Message $errorMsg -Context @{ filePath = $fullPath; extension = $extension }
            throw [System.ArgumentException] $errorMsg
        }

        # Read file content
        $content = try {
            Get-Content -Path $fullPath -Raw -Encoding $Encoding -ErrorAction Stop
        }
        catch {
            Write-ErrorLog -Message "Failed to read input file" -Context @{
                filePath = $fullPath
                error    = $_.Exception.Message
            } -Exception $_
            throw
        }

        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-WarnLog -Message "Input file is empty" -Context @{ filePath = $fullPath }
            return @()
        }

        $entries = @()

        switch ($extension) {
            '.json' {
                $entries = Parse-JsonInput -Content $content -FilePath $fullPath
            }

            { '.txt', '.md', '.rtf' -contains $_ } {
                $entries = Parse-TextInput -Content $content -FilePath $fullPath
            }
        }

        # Filter out empty/whitespace entries
        $entries = $entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

        Write-InfoLog -Message "Parsed entries from file" -Context @{ filePath = $fullPath; count = $entries.Count }
        return $entries
    }
}

<#
.SYNOPSIS
    Parses JSON content for URLs.
#>
function Parse-JsonInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $entries = @()

    try {
        $data = $Content | ConvertFrom-Json -ErrorAction Stop -Depth 10
    }
    catch {
        Write-ErrorLog -Message "Failed to parse JSON" -Context @{
            filePath = $FilePath
            error    = $_.Exception.Message
        } -Exception $_
        throw
    }

    if ($data -is [array]) {
        # Array of strings or objects
        $entries = $data | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) }
        # Also check objects in array for URL properties
        $objects = $data | Where-Object { $_ -isnot [string] }
        foreach ($obj in $objects) {
            foreach ($prop in $script:JsonUrlProperties) {
                if ($obj.$prop -and -not [string]::IsNullOrWhiteSpace($obj.$prop)) {
                    $entries += $obj.$prop
                }
            }
        }
    }
    elseif ($data -is [string]) {
        $entries = @($data)
    }
    elseif ($data -is [pscustomobject] -or $data -is [hashtable]) {
        # Single object - check URL properties
        foreach ($prop in $script:JsonUrlProperties) {
            if ($data.$prop -and -not [string]::IsNullOrWhiteSpace($data.$prop)) {
                $entries += $data.$prop
            }
        }
        # If no known properties, try all string properties
        if ($entries.Count -eq 0) {
            $props = $data.PSObject.Properties | Where-Object { $_.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($_.Value) }
            foreach ($prop in $props) {
                $entries += $prop.Value
            }
        }
    }

    return $entries
}

<#
.SYNOPSIS
    Parses text content for URLs (delimiter-separated).
#>
function Parse-TextInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    # Split by separators: spaces, tabs, newlines, commas
    $rawEntries = $Content -split $script:SeparatorRegex
    $entries = $rawEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

    return $entries
}

<#
.SYNOPSIS
    Parses command-line arguments into URL entries.

.DESCRIPTION
    Processes arguments that can be:
    - Direct URLs
    - Paths to input files (auto-detected by extension and existence)
    - Mixed URLs and file paths

.PARAMETER Args
    Array of command-line arguments.

.OUTPUTS
    Array of URL strings.

.EXAMPLE
    $urls = Parse-CommandLineEntries -Args $args
#>
function Parse-CommandLineEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Args
    )

    $entries = @()

    Write-DebugLog -Message "Parsing command-line arguments" -Context @{ argCount = $Args.Count }

    foreach ($arg in $Args) {
        $arg = $arg.Trim()
        if ([string]::IsNullOrWhiteSpace($arg)) {
            continue
        }

        # Check if it's a file path (exists and has supported extension)
        $isFile = $false
        if (Test-Path -Path $arg -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($arg).ToLowerInvariant()
            if ($ext -in $script:SupportedExtensions) {
                $isFile = $true
            }
        }

        if ($isFile) {
            Write-DebugLog -Message "Argument detected as input file" -Context @{ arg = $arg }
            try {
                $fileEntries = Parse-InputFile -FilePath $arg
                $entries += $fileEntries
            }
            catch {
                Write-ErrorLog -Message "Failed to parse input file from command line" -Context @{
                    filePath = $arg
                    error    = $_.Exception.Message
                } -Exception $_
                # Continue processing other args instead of throwing
            }
        }
        else {
            # Treat as direct URL
            $entries += $arg
        }
    }

    Write-InfoLog -Message "Parsed command-line entries" -Context @{ count = $entries.Count }
    return $entries
}

<#
.SYNOPSIS
    Collects URLs interactively from user input.

.DESCRIPTION
    Prompts user for URLs or file paths, one per line.
    Empty line ends input. Supports same file types as Parse-InputFile.

.PARAMETER Prompt
    Prompt string for each line.

.PARAMETER MaxEntries
    Maximum number of entries to accept (0 = unlimited).

.OUTPUTS
    Array of URL strings.

.EXAMPLE
    $urls = Parse-InteractiveInput -Prompt 'Enter URL or file path'
#>
function Parse-InteractiveInput {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Prompt = 'URL or file path',

        [Parameter()]
        [ValidateRange(0, 10000)]
        [int]$MaxEntries = 0
    )

    Write-Host ""
    Write-Host "Enter URLs or file paths (one per line, empty line to finish):" -ForegroundColor Cyan
    Write-Host "Supported file types: $($script:SupportedExtensions -join ', ')" -ForegroundColor Gray
    Write-Host "Separators in text files: spaces, commas, newlines" -ForegroundColor Gray
    if ($MaxEntries -gt 0) {
        Write-Host "Maximum entries: $MaxEntries" -ForegroundColor Gray
    }
    Write-Host ""

    $entries = @()
    $lineNum = 1

    while ($true) {
        if ($MaxEntries -gt 0 -and $entries.Count -ge $MaxEntries) {
            Write-Host "Maximum entries ($MaxEntries) reached." -ForegroundColor Yellow
            break
        }

        try {
            $userInput = Read-Host "[$lineNum] $Prompt"
        }
        catch {
            # Ctrl+C or EOF
            Write-Host ""
            Write-WarnLog -Message "Interactive input cancelled"
            break
        }

        if ($null -eq $userInput -or [string]::IsNullOrWhiteSpace($userInput)) {
            break
        }

        $userInput = $userInput.Trim()

        # Check if it's a file path
        $isFile = $false
        if (Test-Path -Path $userInput -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($userInput).ToLowerInvariant()
            if ($ext -in $script:SupportedExtensions) {
                $isFile = $true
            }
        }

        if ($isFile) {
            Write-DebugLog -Message "Interactive input detected as file" -Context @{ input = $userInput }
            try {
                $fileEntries = Parse-InputFile -FilePath $userInput
                $entries += $fileEntries
                Write-Host "  Loaded $($fileEntries.Count) entries from $userInput" -ForegroundColor Green
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host ("  Failed to load {0}: {1}" -f $userInput, $errorMessage) -ForegroundColor Red
                Write-ErrorLog -Message "Failed to load interactive input file" -Context @{
                    filePath = $userInput
                    error    = $errorMessage
                } -Exception $_
            }
        }
        else {
            # Treat as direct URL
            $entries += $userInput
        }

        $lineNum++
    }

    Write-InfoLog -Message "Interactive input complete" -Context @{ count = $entries.Count }
    return $entries
}

<#
.SYNOPSIS
    Validates and normalizes a collection of raw entries using Normalize-Url.

.PARAMETER Entries
    Raw URL strings to validate.

.PARAMETER AssumeHttps
    Passed to Normalize-Url.

.OUTPUTS
    Array of validated System.Uri objects (successful normalizations only).
#>
function Validate-AndNormalizeEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string[]]$Entries,

        [Parameter()]
        [bool]$AssumeHttps = $true
    )

    process {
        $validated = @()
        foreach ($entry in $Entries) {
            $uri = Normalize-Url -Url $entry -AssumeHttps $AssumeHttps
            if ($uri) {
                $validated += $uri
            }
            else {
                Write-WarnLog -Message "Skipping invalid entry" -Context @{ entry = $entry }
            }
        }
        return $validated
    }
}

Export-ModuleMember -Function @(
    'Parse-InputFile'
    'Parse-CommandLineEntries'
    'Parse-InteractiveInput'
    'Validate-AndNormalizeEntries'
)