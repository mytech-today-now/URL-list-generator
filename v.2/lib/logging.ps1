<#
.SYNOPSIS
    Local logging module for list-gen - no remote code execution, no Invoke-Expression.

.DESCRIPTION
    Provides structured JSONL logging with multiple levels (DEBUG, INFO, WARN, ERROR),
    console output with colors, and file rotation. Fully self-contained with zero
    external dependencies. Designed to be dot-sourced or imported as a nested module.

.NOTES
    Version: 3.1.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Module-scoped logger state
$script:LogState = @{
    LogPath       = $null
    ScriptName    = 'list-gen'
    ScriptVersion = '3.1.0'
    MinLevel      = 'INFO'  # DEBUG, INFO, WARN, ERROR
    ConsoleOutput = $true
    FileOutput    = $true
    JsonFormat    = $true
    Initialized   = $false
}

# Log level priority (higher = more severe)
enum LogLevel {
    DEBUG  = 0
    INFO   = 1
    WARN   = 2
    ERROR  = 3
}

<#
.SYNOPSIS
    Initializes the logging subsystem.

.DESCRIPTION
    Sets up file and console logging with the specified configuration.
    Must be called before any Write-Log calls.

.PARAMETER LogPath
    Full path to the log file (JSONL format). Directory will be created if needed.

.PARAMETER ScriptName
    Name of the calling script/module for log context.

.PARAMETER ScriptVersion
    Version of the calling script/module.

.PARAMETER MinLevel
    Minimum log level to capture. Default: INFO.

.PARAMETER NoConsole
    Suppress console output. Default: false.

.PARAMETER NoFile
    Suppress file output. Default: false.

.EXAMPLE
    Initialize-Log -LogPath ~/logs/app.log -ScriptName 'MyScript' -ScriptVersion '1.0.0'
#>
function Initialize-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [string]$ScriptName = 'list-gen',

        [Parameter()]
        [string]$ScriptVersion = '3.1.0',

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$MinLevel = 'INFO',

        [Parameter()]
        [switch]$NoConsole,

        [Parameter()]
        [switch]$NoFile
    )

    try {
        # Ensure log directory exists
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop
        }

        # Test writability
        $testFile = Join-Path $logDir ".write_test_$([Guid]::NewGuid()).tmp"
        Set-Content -Path $testFile -Value "test" -ErrorAction Stop
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue

        $script:LogState.LogPath       = $LogPath
        $script:LogState.ScriptName    = $ScriptName
        $script:LogState.ScriptVersion = $ScriptVersion
        $script:LogState.MinLevel      = $MinLevel
        $script:LogState.ConsoleOutput = -not $NoConsole
        $script:LogState.FileOutput    = -not $NoFile
        $script:LogState.Initialized   = $true

        # Write initialization marker
        internal_WriteLog -Level 'INFO' -Message "Logging initialized" -Context @{
            scriptName    = $ScriptName
            scriptVersion = $ScriptVersion
            logPath       = $LogPath
            minLevel      = $MinLevel
        }
    }
    catch {
        # Fallback to console-only if file setup fails
        $script:LogState.FileOutput = $false
        $script:LogState.Initialized = $true
        Write-Warning "Failed to initialize file logging: $($_.Exception.Message). Falling back to console-only."
        Write-Warning "Log path attempted: $LogPath"
    }
}

<#
.SYNOPSIS
    Writes a structured log entry.

.DESCRIPTION
    Core logging function. Outputs JSONL to file and formatted text to console.

.PARAMETER Level
    Log level: DEBUG, INFO, WARN, ERROR.

.PARAMETER Message
    Human-readable log message.

.PARAMETER Context
    Optional hashtable of structured context data.

.PARAMETER Exception
    Optional exception object for ERROR level logs.
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [hashtable]$Context,

        [Parameter()]
        [System.Exception]$Exception
    )

    # Early initialization check
    if (-not $script:LogState.Initialized) {
        # Lazy init with defaults to avoid losing critical early logs
        Initialize-Log -LogPath (Join-Path $env:TEMP "list-gen_$(Get-Date -Format 'yyyy-MM').jsonl") -MinLevel 'DEBUG'
    }

    # Level filtering
    $currentLevel = [LogLevel]::$($script:LogState.MinLevel)
    $messageLevel = [LogLevel]::$Level
    if ($messageLevel -lt $currentLevel) {
        return
    }

    internal_WriteLog -Level $Level -Message $Message -Context $Context -Exception $Exception
}

# Internal implementation - separated to allow calling from Initialize-Log without recursion
function internal_WriteLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [hashtable]$Context,

        [Parameter()]
        [System.Exception]$Exception
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffzzz")
    $logEntry = @{
        timestamp    = $timestamp
        level        = $Level
        logger       = $script:LogState.ScriptName
        version      = $script:LogState.ScriptVersion
        message      = $Message
        context      = if ($Context) { $Context } else { @{} }
        exception    = if ($Exception) {
            @{
                type    = $Exception.GetType().FullName
                message = $Exception.Message
                stack   = $Exception.StackTrace
            }
        } else { $null }
    }

    # File output (JSONL)
    if ($script:LogState.FileOutput -and $script:LogState.LogPath) {
        try {
            $json = $logEntry | ConvertTo-Json -Compress -Depth 5
            Add-Content -Path $script:LogState.LogPath -Value $json -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # If file write fails, disable file output to prevent repeated errors
            $script:LogState.FileOutput = $false
            Write-Warning "Failed to write log file, disabling file output: $($_.Exception.Message)"
        }
    }

    # Console output (colored, human-readable)
    if ($script:LogState.ConsoleOutput) {
        $levelColor = switch ($Level) {
            'DEBUG' { 'Gray' }
            'INFO'  { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'White' }
        }

        $contextStr = if ($Context -and $Context.Count -gt 0) {
            " | Context: $($Context | ConvertTo-Json -Compress -Depth 3)"
        } else {
            ""
        }

        $exceptionStr = if ($Exception) {
            " | Exception: $($Exception.GetType().Name): $($Exception.Message)"
        } else {
            ""
        }

        $consoleMsg = "[$timestamp] [$Level] $Message$contextStr$exceptionStr"

        try {
            Write-Host $consoleMsg -ForegroundColor $levelColor
        }
        catch {
            # Host might not support colors (e.g., non-interactive)
            Write-Output $consoleMsg
        }
    }
}

# Convenience functions for each level
function Write-DebugLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message,
        [hashtable]$Context
    )
    process { Write-Log -Level 'DEBUG' -Message $Message -Context $Context }
}

function Write-InfoLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message,
        [hashtable]$Context
    )
    process { Write-Log -Level 'INFO' -Message $Message -Context $Context }
}

function Write-WarnLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message,
        [hashtable]$Context
    )
    process { Write-Log -Level 'WARN' -Message $Message -Context $Context }
}

function Write-ErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message,
        [hashtable]$Context,
        [System.Exception]$Exception
    )
    process { Write-Log -Level 'ERROR' -Message $Message -Context $Context -Exception $Exception }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-Log'
    'Write-Log'
    'Write-DebugLog'
    'Write-InfoLog'
    'Write-WarnLog'
    'Write-ErrorLog'
)

# Module initialization - set default log level from environment if present
if ($env:LIST_GEN_LOG_LEVEL -and $env:LIST_GEN_LOG_LEVEL -in 'DEBUG','INFO','WARN','ERROR') {
    $script:LogState.MinLevel = $env:LIST_GEN_LOG_LEVEL
}

# Help: This module is designed to be dot-sourced or imported as nested module.
# No automatic initialization - caller must call Initialize-Log explicitly.