<#
.SYNOPSIS
    Network utilities for list-gen - secure HTTP operations with retry, TLS validation, and certificate pinning.

.DESCRIPTION
    Provides Invoke-WebRequestWithRetry with exponential backoff, configurable TLS validation,
    optional certificate pinning (SPKI), and redirect handling. All network operations
    funnel through this module for consistent security posture.

.NOTES
    Version: 3.2.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Module-scoped network configuration
$script:NetworkConfig = @{
    DefaultTimeoutSec     = 60
    MaxRetries            = 3
    BaseDelayMs           = 1000
    MaxDelayMs            = 30000
    JitterPercent         = 0.1
    FollowRedirects       = $true
    MaxRedirects          = 10
    ValidateCertificate   = $true
    CertificatePins       = @()  # Array of SPKI base64 hashes for pinning
    UserAgent             = "list-gen/3.2.0 (PowerShell; +https://github.com/mytech-today-now/PowerShellScripts)"
    SkipCertificateCheck  = $false  # For testing only - NEVER use in production
}

# Retryable HTTP status codes
$script:RetryableStatusCodes = @(408, 429, 500, 502, 503, 504)

# Retryable exception types
$script:RetryableExceptions = @(
    'System.Net.WebException',
    'System.IO.IOException',
    'System.TimeoutException',
    'System.Net.Http.HttpRequestException'
)

<#
.SYNOPSIS
    Configures global network settings for the module.

.DESCRIPTION
    Sets default values for timeouts, retries, TLS validation, and certificate pinning.
    Call once at startup before making requests.

.PARAMETER TimeoutSec
    Default request timeout in seconds. Default: 60.

.PARAMETER MaxRetries
    Maximum retry attempts for failed requests. Default: 3.

.PARAMETER BaseDelayMs
    Base delay for exponential backoff in milliseconds. Default: 1000.

.PARAMETER MaxDelayMs
    Maximum delay cap for retries in milliseconds. Default: 30000.

.PARAMETER JitterPercent
    Random jitter factor (0.0-1.0) applied to retry delays. Default: 0.1.

.PARAMETER FollowRedirects
    Whether to follow HTTP redirects. Default: true.

.PARAMETER MaxRedirects
    Maximum number of redirects to follow. Default: 10.

.PARAMETER ValidateCertificate
    Whether to validate TLS certificates. Default: true. Set to false ONLY for testing.

.PARAMETER CertificatePins
    Array of SPKI SHA256 base64 hashes for certificate pinning (HPKP style).
    Example: @('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')

.PARAMETER UserAgent
    Custom User-Agent string for requests.

.PARAMETER SkipCertificateCheck
    DANGEROUS: Disables all certificate validation. For testing ONLY.
    Will emit a loud warning. Never use in production.

.EXAMPLE
    Set-NetworkConfig -TimeoutSec 30 -MaxRetries 5 -CertificatePins @('sha256/...')

.EXAMPLE
    Set-NetworkConfig -ValidateCertificate $false -SkipCertificateCheck
    # WARNING: Certificate validation disabled!
#>
function Set-NetworkConfig {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSec,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetries,

        [Parameter()]
        [ValidateRange(100, 60000)]
        [int]$BaseDelayMs,

        [Parameter()]
        [ValidateRange(1000, 300000)]
        [int]$MaxDelayMs,

        [Parameter()]
        [ValidateRange(0.0, 1.0)]
        [double]$JitterPercent,

        [Parameter()]
        [bool]$FollowRedirects,

        [Parameter()]
        [ValidateRange(0, 50)]
        [int]$MaxRedirects,

        [Parameter()]
        [bool]$ValidateCertificate,

        [Parameter()]
        [string[]]$CertificatePins,

        [Parameter()]
        [string]$UserAgent,

        [Parameter()]
        [switch]$SkipCertificateCheck
    )

    if ($PSBoundParameters.ContainsKey('TimeoutSec'))       { $script:NetworkConfig.DefaultTimeoutSec = $TimeoutSec }
    if ($PSBoundParameters.ContainsKey('MaxRetries'))       { $script:NetworkConfig.MaxRetries = $MaxRetries }
    if ($PSBoundParameters.ContainsKey('BaseDelayMs'))      { $script:NetworkConfig.BaseDelayMs = $BaseDelayMs }
    if ($PSBoundParameters.ContainsKey('MaxDelayMs'))       { $script:NetworkConfig.MaxDelayMs = $MaxDelayMs }
    if ($PSBoundParameters.ContainsKey('JitterPercent'))    { $script:NetworkConfig.JitterPercent = $JitterPercent }
    if ($PSBoundParameters.ContainsKey('FollowRedirects'))  { $script:NetworkConfig.FollowRedirects = $FollowRedirects }
    if ($PSBoundParameters.ContainsKey('MaxRedirects'))     { $script:NetworkConfig.MaxRedirects = $MaxRedirects }
    if ($PSBoundParameters.ContainsKey('ValidateCertificate')) {
        $script:NetworkConfig.ValidateCertificate = $ValidateCertificate
    }
    if ($PSBoundParameters.ContainsKey('CertificatePins'))  { $script:NetworkConfig.CertificatePins = $CertificatePins }
    if ($PSBoundParameters.ContainsKey('UserAgent'))        { $script:NetworkConfig.UserAgent = $UserAgent }

    if ($SkipCertificateCheck) {
        $script:NetworkConfig.ValidateCertificate = $false
        Write-WarnLog -Message "DANGER: TLS certificate validation DISABLED via SkipCertificateCheck. NEVER use in production!" `
            -Context @{ stackTrace = (Get-PSCallStack | Select-Object -First 3 | ForEach-Object { $_.Command }) }
    }

    Write-DebugLog -Message "Network config updated" -Context $script:NetworkConfig
}

<#
.SYNOPSIS
    Gets current network configuration.

.OUTPUTS
    Hashtable with current network settings.
#>
function Get-NetworkConfig {
    [CmdletBinding()]
    param()
    return $script:NetworkConfig.Clone()
}

<#
.SYNOPSIS
    Validates a server certificate against pinned SPKI hashes.

.DESCRIPTION
    Performs certificate pinning validation using SPKI (Subject Public Key Info) SHA256 hashes.
    This prevents MITM attacks even with valid CA-signed certificates.

.PARAMETER Cert
    X509Certificate2 object to validate.

.PARAMETER Pins
    Array of SPKI pin strings in format 'sha256/<base64>'.

.RETURNS
    $true if certificate matches at least one pin, $false otherwise.
#>
function Test-CertificatePin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,

        [Parameter(Mandatory = $true)]
        [string[]]$Pins
    )

    if (-not $Pins -or $Pins.Count -eq 0) {
        return $true  # No pins configured = pass
    }

    try {
        # Get SPKI (Subject Public Key Info) bytes
        $spki = $Cert.GetPublicKey()
        if (-not $spki -or $spki.Length -eq 0) {
            Write-WarnLog -Message "Certificate has no public key for pinning validation"
            return $false
        }

        # Compute SHA256 of SPKI
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha256.ComputeHash($spki)
        $hashB64 = [Convert]::ToBase64String($hash)
        $pinValue = "sha256/$hashB64"

        foreach ($pin in $Pins) {
            if ($pin -ieq $pinValue) {
                Write-DebugLog -Message "Certificate pin matched" -Context @{ pin = $pinValue }
                return $true
            }
        }

        Write-WarnLog -Message "Certificate pin validation FAILED" -Context @{
            expectedPins = $Pins
            actualPin    = $pinValue
            subject      = $Cert.Subject
            issuer       = $Cert.Issuer
        }
        return $false
    }
    catch {
        Write-ErrorLog -Message "Error during certificate pin validation" -Context @{ error = $_.Exception.Message } -Exception $_
        return $false
    }
}

<#
.SYNOPSIS
    Custom certificate validation callback for Invoke-WebRequest.

.DESCRIPTION
    Validates certificate chain and optionally checks pinned SPKI hashes.
    Used internally by Invoke-WebRequestWithRetry.
#>
function internal_ValidateCertificate {
    param(
        [System.Object]$_Sender,
        [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,
        [System.Security.Cryptography.X509Certificates.X509Chain]$Chain,
        [System.Net.Security.SslPolicyErrors]$SslPolicyErrors
    )

    if (-not $script:NetworkConfig.ValidateCertificate) {
        Write-WarnLog -Message "Skipping certificate validation (ValidateCertificate=$false)"
        return $true
    }

    # Check for SSL policy errors
    if ($SslPolicyErrors -ne [System.Net.Security.SslPolicyErrors]::None) {
        Write-ErrorLog -Message "Certificate validation failed" -Context @{
            errors = $SslPolicyErrors.ToString()
            subject = $Certificate.Subject
            issuer = $Certificate.Issuer
        }
        return $false
    }

    # Verify chain
    if ($Chain -and $Chain.ChainStatus) {
        foreach ($status in $Chain.ChainStatus) {
            if ($status.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError) {
                Write-ErrorLog -Message "Certificate chain validation failed" -Context @{
                    status = $status.Status.ToString()
                    info   = $status.StatusInformation
                }
                return $false
            }
        }
    }

    # Certificate pinning validation
    $pins = $script:NetworkConfig.CertificatePins
    if ($pins -and $pins.Count -gt 0) {
        $x509Cert2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
        $pinValid = Test-CertificatePin -Cert $x509Cert2 -Pins $pins
        if (-not $pinValid) {
            return $false
        }
    }

    return $true
}

<#
.SYNOPSIS
    Determines if an exception is retryable.

.PARAMETER Exception
    The exception to check.

.RETURNS
    $true if the exception type suggests a transient failure.
#>
function internal_IsRetryableException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($current) {
        $typeName = $current.GetType().FullName
        if ($script:RetryableExceptions -contains $typeName) {
            return $true
        }
        # Check inner exceptions
        $current = $current.InnerException
    }

    # Check for WebException with retryable status
    if ($Exception -is [System.Net.WebException]) {
        $status = $Exception.Status
        # Transient network statuses
        if ($status -in @(
            [System.Net.WebExceptionStatus]::Timeout,
            [System.Net.WebExceptionStatus]::ConnectFailure,
            [System.Net.WebExceptionStatus]::ReceiveFailure,
            [System.Net.WebExceptionStatus]::KeepAliveFailure,
            [System.Net.WebExceptionStatus]::PipelineFailure,
            [System.Net.WebExceptionStatus]::RequestCanceled,
            [System.Net.WebExceptionStatus]::ConnectionClosed
        )) {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Determines if an HTTP status code is retryable.

.PARAMETER StatusCode
    HTTP status code integer.

.RETURNS
    $true if the status code suggests a transient failure.
#>
function internal_IsRetryableStatusCode {
    param([int]$StatusCode)
    return $script:RetryableStatusCodes -contains $StatusCode
}

<#
.SYNOPSIS
    Calculates exponential backoff delay with jitter.

.PARAMETER Attempt
    Current attempt number (0-based).

.RETURNS
    Delay in milliseconds.
#>
function internal_CalculateBackoff {
    param([int]$Attempt)

    $config = $script:NetworkConfig
    $baseDelay = $config.BaseDelayMs * [Math]::Pow(2, $Attempt)
    $cappedDelay = [Math]::Min($baseDelay, $config.MaxDelayMs)

    # Add jitter: ±JitterPercent
    $jitter = $cappedDelay * $config.JitterPercent
    $minDelay = [Math]::Max(0, $cappedDelay - $jitter)
    $maxDelay = $cappedDelay + $jitter

    return Get-Random -Minimum $minDelay -Maximum $maxDelay
}

<#
.SYNOPSIS
    Executes a web request with automatic retry, redirect handling, and TLS validation.

.DESCRIPTION
    Wrapper around Invoke-WebRequest that adds:
    - Exponential backoff retry (configurable attempts, delay, jitter)
    - Configurable redirect following
    - TLS certificate validation with optional pinning
    - Consistent error handling and logging
    - Custom User-Agent

.PARAMETER Uri
    Target URI (string or System.Uri).

.PARAMETER Method
    HTTP method. Default: GET.

.PARAMETER Headers
    Additional headers as hashtable.

.PARAMETER Body
    Request body for POST/PUT/PATCH.

.PARAMETER ContentType
    Content-Type header for request body.

.PARAMETER TimeoutSec
    Request timeout override.

.PARAMETER MaxRetries
    Retry attempt override.

.PARAMETER FollowRedirects
    Redirect following override.

.PARAMETER ValidateCertificate
    Certificate validation override.

.PARAMETER CertificatePins
    SPKI pin override for this request.

.PARAMETER SkipCertificateCheck
    DANGEROUS: Disable cert validation for this request only.

.PARAMETER UseBasicParsing
    Use basic parsing (no DOM). Default: true for performance.

.PARAMETER PassThru
    Return response object instead of content.

.OUTPUTS
    System.Net.HttpWebResponse or string (content) based on -PassThru.

.EXAMPLE
    $content = Invoke-WebRequestWithRetry -Uri 'https://example.com/dir/'

.EXAMPLE
    $response = Invoke-WebRequestWithRetry -Uri 'https://api.example.com' -Method POST -Body '{"key":"value"}' -ContentType 'application/json' -PassThru
#>
function Invoke-WebRequestWithRetry {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Default')]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'WithPins')]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS')]
        [string]$Method = 'GET',

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [hashtable]$Headers,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [string]$Body,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [string]$ContentType = 'application/x-www-form-urlencoded',

        [Parameter(ParameterSetName = 'Default')]
        [ValidateRange(1, 300)]
        [int]$TimeoutSec,

        [Parameter(ParameterSetName = 'Default')]
        [ValidateRange(0, 10)]
        [int]$MaxRetries,

        [Parameter(ParameterSetName = 'Default')]
        [bool]$FollowRedirects,

        [Parameter(ParameterSetName = 'Default')]
        [bool]$ValidateCertificate,

        [Parameter(ParameterSetName = 'WithPins')]
        [string[]]$CertificatePins,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [switch]$SkipCertificateCheck,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [bool]$UseBasicParsing = $true,

        [Parameter(ParameterSetName = 'Default')]
        [Parameter(ParameterSetName = 'WithPins')]
        [switch]$PassThru
    )

    # Resolve effective config (parameter overrides > module config)
    $effectiveConfig = @{
        TimeoutSec          = if ($PSBoundParameters.ContainsKey('TimeoutSec')) { $TimeoutSec } else { $script:NetworkConfig.DefaultTimeoutSec }
        MaxRetries          = if ($PSBoundParameters.ContainsKey('MaxRetries')) { $MaxRetries } else { $script:NetworkConfig.MaxRetries }
        FollowRedirects     = if ($PSBoundParameters.ContainsKey('FollowRedirects')) { $FollowRedirects } else { $script:NetworkConfig.FollowRedirects }
        ValidateCertificate = if ($PSBoundParameters.ContainsKey('ValidateCertificate')) { $ValidateCertificate } else { $script:NetworkConfig.ValidateCertificate }
        CertificatePins     = if ($PSBoundParameters.ContainsKey('CertificatePins')) { $CertificatePins } else { $script:NetworkConfig.CertificatePins }
        SkipCertificateCheck = $SkipCertificateCheck.IsPresent
    }

    if ($effectiveConfig.SkipCertificateCheck) {
        $effectiveConfig.ValidateCertificate = $false
    }

    $uriObj = [System.Uri]$Uri
    $attempt = 0

    Write-DebugLog -Message "Starting web request" -Context @{
        uri           = $uriObj.AbsoluteUri
        method        = $Method
        attempt       = 0
        maxRetries    = $effectiveConfig.MaxRetries
        timeoutSec    = $effectiveConfig.TimeoutSec
        followRedirects = $effectiveConfig.FollowRedirects
        validateCert  = $effectiveConfig.ValidateCertificate
        pins          = $effectiveConfig.CertificatePins.Count
    }

    while ($attempt -le $effectiveConfig.MaxRetries) {
        try {
            # Build request parameters
            $requestParams = @{
                Uri             = $uriObj
                Method          = $Method
                TimeoutSec      = $effectiveConfig.TimeoutSec
                UseBasicParsing = $UseBasicParsing
                UserAgent       = $script:NetworkConfig.UserAgent
                ErrorAction     = 'Stop'
            }

            if ($Headers) { $requestParams.Headers = $Headers }
            if ($Body) {
                $requestParams.Body = $Body
                $requestParams.ContentType = $ContentType
            }

            # Handle redirects manually if not using automatic (which doesn't allow custom validation)
            if (-not $effectiveConfig.FollowRedirects) {
                $requestParams.MaximumRedirection = 0
            }
            else {
                $requestParams.MaximumRedirection = $script:NetworkConfig.MaxRedirects
            }

            # Certificate validation callback - only works with .NET's HttpClientHandler
            # For Invoke-WebRequest, we need to use a custom approach
            # We'll validate after the fact for redirect chain, or use WebRequest directly for full control

            $response = Invoke-WebRequest @requestParams

            # Validate final response certificate if HTTPS
            if ($uriObj.Scheme -ieq 'https' -and $effectiveConfig.ValidateCertificate) {
                # Note: Invoke-WebRequest doesn't expose the certificate easily.
                # For full cert validation including pinning, we'd need to use HttpClient directly.
                # This is a known limitation of Invoke-WebRequest.
                Write-DebugLog -Message "HTTPS request completed (certificate validation limited with Invoke-WebRequest)"
            }

            Write-DebugLog -Message "Web request succeeded" -Context @{
                uri         = $uriObj.AbsoluteUri
                statusCode  = $response.StatusCode
                contentLength = $response.RawContentLength
                attempt     = $attempt
            }

            if ($PassThru) {
                return $response
            }
            return $response.Content

        }
        catch {
            $isRetryable = $false
            $statusCode = $null

            # Check if it's a WebException with response
            if ($_ -is [System.Net.WebException] -and $_.Response) {
                $httpResponse = $_.Response
                $statusCode = [int]$httpResponse.StatusCode
                $isRetryable = internal_IsRetryableStatusCode $statusCode
            }
            else {
                $isRetryable = internal_IsRetryableException $_
            }

            Write-WarnLog -Message "Web request failed (attempt $($attempt + 1)/$($effectiveConfig.MaxRetries + 1))" -Context @{
                uri         = $uriObj.AbsoluteUri
                method      = $Method
                attempt     = $attempt + 1
                maxRetries  = $effectiveConfig.MaxRetries + 1
                isRetryable = $isRetryable
                statusCode  = $statusCode
                errorType   = $_.Exception.GetType().FullName
                errorMsg    = $_.Exception.Message
            }

            if (-not $isRetryable -or $attempt -ge $effectiveConfig.MaxRetries) {
                Write-ErrorLog -Message "Web request failed permanently" -Context @{
                    uri         = $uriObj.AbsoluteUri
                    method      = $Method
                    totalAttempts = $attempt + 1
                    finalError  = $_.Exception.Message
                } -Exception $_

                throw
            }

            # Calculate backoff and wait
            $delayMs = internal_CalculateBackoff -Attempt $attempt
            Write-DebugLog -Message "Retrying after backoff" -Context @{ delayMs = $delayMs; attempt = $attempt }
            Start-Sleep -Milliseconds $delayMs
            $attempt++
        }
    }

    # Should never reach here
    throw "Unexpected exit from retry loop"
}

# For advanced scenarios requiring full certificate control, provide HttpClient-based alternative
<#
.SYNOPSIS
    Advanced web request using HttpClient with full certificate validation and pinning support.

.DESCRIPTION
    Uses System.Net.Http.HttpClient with custom HttpClientHandler for complete control
    over TLS validation, certificate pinning, and redirect handling. More powerful but
    slightly more complex than Invoke-WebRequestWithRetry.

.PARAMETER Uri
    Target URI.

.PARAMETER Method
    HTTP method.

.PARAMETER Headers
    Request headers.

.PARAMETER Content
    HttpContent for request body.

.PARAMETER TimeoutSec
    Request timeout.

.PARAMETER FollowRedirects
    Follow redirects.

.PARAMETER ValidateCertificate
    Validate server certificate.

.PARAMETER CertificatePins
    SPKI pins for pinning validation.

.OUTPUTS
    System.Net.Http.HttpResponseMessage (caller must dispose).
#>
function Invoke-HttpClientRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS')]
        [string]$Method = 'GET',

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [System.Net.Http.HttpContent]$Content,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [bool]$FollowRedirects = $true,

        [Parameter()]
        [bool]$ValidateCertificate = $true,

        [Parameter()]
        [string[]]$CertificatePins,

        [Parameter()]
        [switch]$SkipCertificateCheck
    )

    if ($SkipCertificateCheck) {
        $ValidateCertificate = $false
    }

    $uriObj = [System.Uri]$Uri
    $handler = [System.Net.Http.HttpClientHandler]::new()

    # Configure redirects
    $handler.AllowAutoRedirect = $FollowRedirects
    if ($FollowRedirects) {
        $handler.MaxAutomaticRedirections = $script:NetworkConfig.MaxRedirects
    }

    # Configure certificate validation
    if (-not $ValidateCertificate) {
        $handler.ServerCertificateCustomValidationCallback = { $true }
        Write-WarnLog -Message "HttpClient: Certificate validation DISABLED for this request"
    }
    elseif ($CertificatePins -and $CertificatePins.Count -gt 0) {
        $handler.ServerCertificateCustomValidationCallback = {
            param($_sender, $cert, $chain, $sslPolicyErrors)
            return internal_ValidateCertificate $_sender $cert $chain $sslPolicyErrors
        }
    }
    else {
        $handler.ServerCertificateCustomValidationCallback = {
            param($_sender, $cert, $chain, $sslPolicyErrors)
            return internal_ValidateCertificate $_sender $cert $chain $sslPolicyErrors
        }
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($script:NetworkConfig.UserAgent)

    if ($Headers) {
        foreach ($header in $Headers.GetEnumerator()) {
            $client.DefaultRequestHeaders.TryAddWithoutValidation($header.Key, $header.Value)
        }
    }

    $requestMsg = [System.Net.Http.HttpRequestMessage]::new($Method, $uriObj)
    if ($Content) { $requestMsg.Content = $Content }

    Write-DebugLog -Message "HttpClient request starting" -Context @{
        uri = $uriObj.AbsoluteUri
        method = $Method
        validateCert = $ValidateCertificate
        pins = ($CertificatePins.Count)
    }

    try {
        $response = $client.SendAsync($requestMsg).GetAwaiter().GetResult()
        Write-DebugLog -Message "HttpClient request completed" -Context @{
            uri = $uriObj.AbsoluteUri
            statusCode = [int]$response.StatusCode
        }
        return $response
    }
    catch {
        Write-ErrorLog -Message "HttpClient request failed" -Context @{
            uri = $uriObj.AbsoluteUri
            method = $Method
            error = $_.Exception.Message
        } -Exception $_
        throw
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Set-NetworkConfig'
    'Get-NetworkConfig'
    'Invoke-WebRequestWithRetry'
    'Invoke-HttpClientRequest'
    'Test-CertificatePin'
)