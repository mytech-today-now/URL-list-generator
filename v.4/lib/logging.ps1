<#
.SYNOPSIS
    Structured logging infrastructure for list-gen module

.DESCRIPTION
    Provides leveled logging (Debug, Verbose, Info, Warning, Error, Critical) with
    structured output, timestamps, and configurable sinks (console, file, ETW).

.NOTES
    This module has no dependencies and should be loaded first.
#>

Set-StrictMode -Version Latest

#region Private Module State
$script:LogConfig = @{
    Level           = 'Info'      # Debug, Verbose, Info, Warning, Error, Critical
    TimestampFormat = 'yyyy-MM-dd HH:mm:ss.fff'
    EnableColors    = $true
    EnableFile      = $false
    FilePath        = $null
    MaxFileSizeMB   = 10
    MaxFiles        = 5
    IncludeContext  = $true
    Encoding        = [System.Text.UTF8Encoding]::new($false)  # UTF8NoBOM
}

$script:LogLevels = @{
    'Debug'    = 0
    'Verbose'  = 1
    'Info'     = 2
    'Warning'  = 3
    'Error'    = 4
    'Critical' = 5
}

$script:ConsoleColors = @{
    'Debug'    = 'Gray'
    'Verbose'  = 'Cyan'
    'Info'     = 'Green'
    'Warning'  = 'Yellow'
    'Error'    = 'Red'
    'Critical' = 'Magenta'
}

$script:FileStream = $null
#endregion

#region Public Functions

function Set-LogConfig {
    <#
    .SYNOPSIS
        Configure global logging settings

    .DESCRIPTION
        Sets logging level, output destinations, formatting options, and file rotation.

    .PARAMETER Level
        Minimum log level to output. Valid values: Debug, Verbose, Info, Warning, Error, Critical

    .PARAMETER EnableColors
        Enable ANSI color codes in console output

    .PARAMETER EnableFile
        Enable file logging

    .PARAMETER FilePath
        Path to log file (required if EnableFile is $true)

    .PARAMETER MaxFileSizeMB
        Maximum size of log file before rotation (default: 10MB)

    .PARAMETER MaxFiles
        Maximum number of rotated log files to keep (default: 5)

    .PARAMETER IncludeContext
        Include caller context (function, line) in log output

    .EXAMPLE
        Set-LogConfig -Level Debug -EnableFile -FilePath './logs/list-gen.log'

    .EXAMPLE
        Set-LogConfig -Level Warning -EnableColors:$false
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Debug','Verbose','Info','Warning','Error','Critical')]
        [string]$Level = 'Info',

        [switch]$EnableColors,

        [switch]$EnableFile,

        [string]$FilePath,

        [ValidateRange(1, 100)]
        [int]$MaxFileSizeMB = 10,

        [ValidateRange(1, 50)]
        [int]$MaxFiles = 5,

        [switch]$IncludeContext
    )

    $script:LogConfig.Level = $Level
    if ($PSBoundParameters.ContainsKey('EnableColors')) { $script:LogConfig.EnableColors = $EnableColors.IsPresent }
    if ($PSBoundParameters.ContainsKey('EnableFile'))   { $script:LogConfig.EnableFile = $EnableFile.IsPresent }
    if ($PSBoundParameters.ContainsKey('FilePath'))     { $script:LogConfig.FilePath = $FilePath }
    if ($PSBoundParameters.ContainsKey('MaxFileSizeMB')) { $script:LogConfig.MaxFileSizeMB = $MaxFileSizeMB }
    if ($PSBoundParameters.ContainsKey('MaxFiles'))     { $script:LogConfig.MaxFiles = $MaxFiles }
    if ($PSBoundParameters.ContainsKey('IncludeContext')) { $script:LogConfig.IncludeContext = $IncludeContext.IsPresent }

    # Initialize file stream if enabled
    if ($script:LogConfig.EnableFile -and $script:LogConfig.FilePath) {
        Initialize-LogFile
    }

    Write-Log -Level 'Info' -Message "Logging configured: Level=$Level, File=$($script:LogConfig.EnableFile), Colors=$($script:LogConfig.EnableColors)"
}

function Write-Log {
    <#
    .SYNOPSIS
        Write a structured log entry

    .DESCRIPTION
        Core logging function with level filtering, formatting, and multi-sink output.

    .PARAMETER Level
        Log level (Debug, Verbose, Info, Warning, Error, Critical)

    .PARAMETER Message
        Log message (supports composite formatting with -f operator)

    .PARAMETER Args
        Arguments for composite formatting

    .PARAMETER Exception
        Exception object to log (includes stack trace)

    .PARAMETER Category
        Logical category for filtering (e.g., 'Network', 'Parsing', 'Export')

    .PARAMETER Context
        Additional structured data as hashtable

    .EXAMPLE
        Write-Log -Level Info -Message "Processing URL: {0}" -Args @($url) -Category 'Network'

    .EXAMPLE
        Write-Log -Level Error -Message "Request failed" -Exception $ex -Context @{ Url=$url; StatusCode=500 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Verbose','Info','Warning','Error','Critical')]
        [string]$Level,

        [Parameter(Mandatory, Position=0)]
        [string]$Message,

        [object[]]$Args = @(),

        [System.Exception]$Exception,

        [string]$Category = 'General',

        [hashtable]$Context = @{}
    )

    # Level filtering
    if ($script:LogLevels[$Level] -lt $script:LogLevels[$script:LogConfig.Level]) {
        return
    }

    # Build log entry
    $timestamp = (Get-Date).ToString($script:LogConfig.TimestampFormat)
    $formattedMessage = if ($Args.Count -gt 0) { $Message -f $Args } else { $Message }
    $callerInfo = Get-CallerInfo
    $logEntry = @{
        Timestamp = $timestamp
        Level     = $Level.PadRight(8)
        Category  = $Category.PadRight(12)
        Message   = $formattedMessage
        Caller    = if ($script:LogConfig.IncludeContext) { $callerInfo } else { '' }
        Context   = $Context
    }

    if ($Exception) {
        $logEntry.Exception = @{
            Type       = $Exception.GetType().FullName
            Message    = $Exception.Message
            StackTrace = $Exception.StackTrace
        }
    }

    # Console output
    Write-LogToConsole $logEntry

    # File output
    if ($script:LogConfig.EnableFile -and $script:LogConfig.FilePath) {
        Write-LogToFile $logEntry
    }

    # PowerShell stream output for pipeline integration
    switch ($Level) {
        'Debug'    { Write-Debug    $formattedMessage }
        'Verbose'  { Write-Verbose  $formattedMessage }
        'Warning'  { Write-Warning  $formattedMessage }
        'Error'    { Write-Error    $formattedMessage }
        default    { Write-Host     $formattedMessage }
    }
}

function Get-LogConfig {
    <#
    .SYNOPSIS
        Get current logging configuration
    #>
    return $script:LogConfig.Clone()
}

#endregion

#region Private Helper Functions

function Initialize-LogFile {
    $path = $script:LogConfig.FilePath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        catch { throw "Cannot create log directory '$dir': $($_.Exception.Message)" }
    }

    # Rotate if needed
    if (Test-Path $path) {
        $sizeMB = (Get-Item $path).Length / 1MB
        if ($sizeMB -ge $script:LogConfig.MaxFileSizeMB) {
            Rotate-LogFiles
        }
    }

    try {
        $script:FileStream = [System.IO.StreamWriter]::new($path, $true, $script:LogConfig.Encoding)
        $script:FileStream.AutoFlush = $true
    }
    catch {
        Log-Warning -Message "Failed to open log file '$path': {0}" -Args $_.Exception.Message -Category 'Logging'
        $script:LogConfig.EnableFile = $false
        $script:FileStream = $null
    }
}

function Rotate-LogFiles {
    $basePath = $script:LogConfig.FilePath
    $maxFiles = $script:LogConfig.MaxFiles

    # Close current stream
    if ($script:FileStream) {
        try { $script:FileStream.Close(); $script:FileStream.Dispose() } catch { }
        $script:FileStream = $null
    }

    # Rotate existing files
    for ($i = $maxFiles - 1; $i -ge 1; $i--) {
        $src = if ($i -eq 1) { $basePath } else { "$basePath.$i" }
        $dst = "$basePath.$($i + 1)"
        if (Test-Path $src) {
            try { Move-Item -Path $src -Destination $dst -Force }
            catch { Log-Warning -Message "Failed to rotate log file '$src': {0}" -Args $_.Exception.Message -Category 'Logging' }
        }
    }
}

function Write-LogToConsole {
    param([hashtable]$Entry)

    $color = if ($script:LogConfig.EnableColors -and $Host.Name -ne 'Visual Studio Code Host') {
        $script:ConsoleColors[$Entry.Level.Trim()]
    } else {
        $null
    }

    $prefix = "[$($Entry.Timestamp)] [$($Entry.Level)] [$($Entry.Category)]"
    $caller = if ($Entry.Caller) { " [$($Entry.Caller)]" } else { '' }
    $line = "$prefix$caller $($Entry.Message)"

    if ($color) {
        Write-Host $line -ForegroundColor $color
    } else {
        Write-Host $line
    }

    # Write context if present
    if ($Entry.Context.Count -gt 0) {
        $ctxStr = ($Entry.Context.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Write-Host "  Context: {$ctxStr}" -ForegroundColor Gray
    }

    if ($Entry.Exception) {
        Write-Host "  Exception: $($Entry.Exception.Type): $($Entry.Exception.Message)" -ForegroundColor Red
        if ($script:LogConfig.Level -eq 'Debug') {
            Write-Host "  StackTrace: $($Entry.Exception.StackTrace)" -ForegroundColor DarkGray
        }
    }
}

function Write-LogToFile {
    param([hashtable]$Entry)

    if (-not $script:FileStream) {
        Initialize-LogFile
    }

    if (-not $script:FileStream) { return }

    try {
        $json = $Entry | ConvertTo-Json -Depth 5 -Compress
        $script:FileStream.WriteLine($json)
    }
    catch {
        # Fallback: write as plain text to avoid losing logs
        $fallback = "[$($Entry.Timestamp)] [$($Entry.Level)] [$($Entry.Category)] $($Entry.Message)"
        try { $script:FileStream.WriteLine($fallback) } catch { }
    }
}

function Get-CallerInfo {
    try {
        $stack = Get-PSCallStack
        # Skip Write-Log, the public function, and Get-CallerInfo
        for ($i = 0; $i -lt $stack.Count; $i++) {
            $frame = $stack[$i]
            if ($frame.Command -notin @('Write-Log', 'Get-CallerInfo', 'Write-Debug', 'Write-Verbose', 'Write-Warning', 'Write-Error', 'Write-Host')) {
                $func = $frame.Command
                $scriptName = Split-Path $frame.ScriptName -Leaf
                if ($scriptName) { return "$scriptName::$func" }
                return $func
            }
        }
        return 'Unknown'
    }
    catch {
        return 'Error'
    }
}

#endregion

#region Convenience Functions (Module-scoped aliases)

function Log-Debug    { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context) Write-Log -Level Debug    -Message $Message -Args $Args -Category $Category -Context $Context }
function Log-Verbose  { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context) Write-Log -Level Verbose  -Message $Message -Args $Args -Category $Category -Context $Context }
function Log-Info     { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context) Write-Log -Level Info     -Message $Message -Args $Args -Category $Category -Context $Context }
function Log-Warning  { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context) Write-Log -Level Warning  -Message $Message -Args $Args -Category $Category -Context $Context }
function Log-Error    { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context, [Exception]$Exception) Write-Log -Level Error    -Message $Message -Args $Args -Category $Category -Context $Context -Exception $Exception }
function Log-Critical { param([string]$Message, [object[]]$Args, [string]$Category, [hashtable]$Context, [Exception]$Exception) Write-Log -Level Critical -Message $Message -Args $Args -Category $Category -Context $Context -Exception $Exception }

#endregion

Export-ModuleMember -Function @(
    'Set-LogConfig',
    'Get-LogConfig',
    'Write-Log',
    'Log-Debug',
    'Log-Verbose',
    'Log-Info',
    'Log-Warning',
    'Log-Error',
    'Log-Critical'
)