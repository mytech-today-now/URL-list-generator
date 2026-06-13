# list-gen v3.0.0

**Web Directory URL List Generator** — Extract file URLs from web directory listings and generate text files containing the full URLs of all files found.

Cross-platform, secure, production-ready PowerShell 7+ module with comprehensive logging, retry logic, TLS validation, and zero external dependencies.

---

## Features

| Feature | Description |
|---------|-------------|
| **Multi-source Input** | Direct URLs, text files (`.txt`, `.md`, `.rtf`), JSON files (arrays, objects with `url`/`href`/`link` properties), interactive entry |
| **Robust URL Handling** | `System.Uri`-based normalization, auto-HTTPS, query/fragment preservation, trailing slash management, relative URL resolution |
| **Smart Extraction** | HTML directory listing parsing, filters non-file links (parent dir, mailto, javascript, fragments), host/path scoping |
| **Collision-Resistant Output** | Timestamp + hash suffixes, sanitized filenames, automatic directory creation |
| **Enterprise Logging** | Structured JSONL logs, configurable levels (DEBUG/INFO/WARN/ERROR), console + file output, cross-platform log directories |
| **Retry & Resilience** | Exponential backoff (configurable), retryable status codes (408, 429, 5xx), network exception handling, redirect following |
| **TLS Security** | Certificate validation, optional SPKI pinning (HPKP-style), dangerous bypass flag (test-only) |
| **Cross-Platform** | Windows, Linux, macOS; uses `$HOME`/`$env:XDG_*` paths; no hardcoded Windows paths |
| **Pipeline-Friendly** | Returns `PSCustomObject` results for further processing |
| **WhatIf/Confirm** | Safe preview and confirmation mode |
| **Zero Dependencies** | Pure PowerShell 7+, no external modules, no `Invoke-Expression` |

---

## Installation

### Option 1: Local Module (Recommended)

```powershell
# Clone or download the repository
git clone https://github.com/mytech-today-now/PowerShellScripts.git
cd PowerShellScripts/URL-list-generator

# Import directly (no installation needed)
Import-Module .\list-gen.psd1

# Or run the CLI entry point
.\list-gen.ps1 -Url https://example.com/files/
```

### Option 2: Install to Module Path

```powershell
# Copy to a PSModulePath location
$dest = Join-Path $env:USERPROFILE '\Documents\PowerShell\Modules\list-gen'
Copy-Item -Path .\* -Destination $dest -Recurse -Force

# Now available globally
Import-Module list-gen
list-gen -Url https://example.com/files/
```

### Option 3: Run from GitHub (One-liner)

```powershell
# SECURITY NOTE: Review code before running remote scripts
irm https://raw.githubusercontent.com/mytech-today-now/PowerShellScripts/main/URL-list-generator/list-gen.ps1 | iex
# Then use: list-gen -Url https://example.com/files/
```

**Required:** PowerShell 7.0+ (`pwsh`)

---

## Quick Start

```powershell
# Process a single directory URL (interactive if no args)
.\list-gen.ps1 https://example.com/files/

# Process multiple URLs
.\list-gen.ps1 https://example.com/files/ https://example.org/data/

# Read URLs from a file (one per line, or space/comma separated)
.\list-gen.ps1 -InputFile .\my-urls.txt

# Process JSON file with URL objects
.\list-gen.ps1 -InputFile .\data.json

# Custom output directory
.\list-gen.ps1 -Url https://example.com/files/ -OutputDir ~/my-output

# Debug logging
.\list-gen.ps1 -Url https://example.com/files/ -LogLevel DEBUG

# Preview without executing
.\list-gen.ps1 -Url https://example.com/files/ -WhatIf
```

---

## Usage

### Command Line (CLI)

```powershell
.\list-gen.ps1
  [[-Url] <String[]>]           # Direct URLs (parameter set: Urls)
  [-InputFile <String>]         # File containing URLs (parameter set: InputFile)
  [-Interactive]                # Interactive multi-line input (default)
  [-OutputDir <String>]         # Output directory (default: ~/Downloads)
  [-LogDir <String>]            # Log directory (default: platform-specific)
  [-LogLevel <DEBUG|INFO|WARN|ERROR>]  # Log verbosity (default: INFO)
  [-TimeoutSec <Int>]           # Request timeout (default: 60)
  [-MaxRetries <Int>]           # Retry attempts (default: 3)
  [-NoRedirects]                # Disable redirect following
  [-NoCertificateValidation]    # DANGER: Disable TLS validation (TEST ONLY)
  [-CertificatePins <String[]>] # SPKI SHA256 pins for certificate pinning
  [-WhatIf]                     # Preview actions without executing
  [-Confirm]                    # Confirm before processing
  [-Help] / [-?]                # Show help
```

**Parameter Sets (mutually exclusive):**
- **Urls** — Direct URL arguments (positional, supports multiple)
- **InputFile** — Path to input file (`-InputFile` / `-i` / `-file`)
- **Interactive** — Prompt for input (`-Interactive` / `-interactive`, default when no args)

### Programmatic API (Module)

```powershell
Import-Module .\list-gen.psd1

# Simple usage
$results = Invoke-ListGen -Urls @(
    'https://example.com/files/',
    'https://example.org/data/'
)

# With options
$results = Invoke-ListGen `
    -InputFile 'urls.txt' `
    -OutputDir '~/output' `
    -LogLevel 'DEBUG' `
    -NetworkParams @{
        TimeoutSec          = 30
        MaxRetries          = 5
        FollowRedirects     = $true
        ValidateCertificate = $true
        CertificatePins     = @('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
    } `
    -WhatIf

# Process results
foreach ($result in $results) {
    if ($result.Success) {
        Write-Host "✓ $($result.SourceUrl) → $($result.FileCount) files → $($result.OutputFile)"
    }
    else {
        Write-Error "✗ $($result.SourceUrl) → $($result.Error)"
    }
}
```

### Input File Formats

**Text (`.txt`, `.md`, `.rtf`)** — Delimiter separated (space, comma, newline, tab):
```text
https://example.com/files/
https://example.org/data/ https://another.com/dir/
```

**JSON (`.json`)** — Multiple formats supported:
```json
// Array of strings
["https://example.com/files/", "https://example.org/data/"]

// Single string
"https://example.com/files/"

// Object with url property
{"url": "https://example.com/files/"}

// Object with href property
{"href": "https://example.com/files/"}

// Array of objects
[{"url": "https://a.com"}, {"url": "https://b.com"}]
```

---

## Output

Each processed directory generates a text file in the output directory:

```
list-gen-example_com_files-20250115-143022-123-a1b2c3d4.txt
```

Format: `{prefix}-{sanitized_source}-{timestamp-ms}-{hash}.txt`

Content: One absolute URL per line
```text
https://example.com/files/document.pdf
https://example.com/files/image.png
https://example.com/files/archive.tar.gz
```

### Result Object (Pipeline)

```powershell
PSCustomObject {
    SourceUrl     = "https://example.com/files/"          # Original input
    NormalizedUrl = "https://example.com/files/"          # Normalized directory URI
    FileCount     = 42                                    # Number of files found
    FileUrls      = @("https://...", "https://...")       # Array of file URLs
    OutputFile    = "~/Downloads/list-gen-...txt"         # Generated file path
    Success       = $true                                 # Processing success
    Error         = $null                                 # Error message if failed
    Timestamp     = "2025-01-15T14:30:22.123+00:00"       # ISO 8601 timestamp
}
```

---

## Logging

Structured JSONL logs written to log directory (default: `~/.local/state/list-gen/logs/` on Linux, `~/Library/Logs/list-gen/` on macOS, `%LOCALAPPDATA%\list-gen\logs\` on Windows).

```json
{"timestamp":"2025-01-15T14:30:22.123+00:00","level":"INFO","logger":"list-gen","version":"3.0.0","message":"Extracted 42 file URLs from directory","context":{"directoryUrl":"https://example.com/files/","fileCount":42}}
{"timestamp":"2025-01-15T14:30:22.456+00:00","level":"INFO","logger":"list-gen","version":"3.0.0","message":"Wrote URL list to file","context":{"outputPath":"~/Downloads/list-gen-...txt","urlCount":42,"encoding":"UTF8NoBOM"}}
```

Console output (colored):
```
[2025-01-15T14:30:22.123+00:00] [INFO] Extracted 42 file URLs from directory | Context: {"directoryUrl":"https://example.com/files/","fileCount":42}
```

Environment variable override:
```powershell
$env:LIST_GEN_LOG_LEVEL = 'DEBUG'
```

---

## Security

### Certificate Pinning (SPKI)

Pin expected certificate public keys to prevent MITM attacks:

```powershell
# Get SPKI hash from a certificate
$cert = Get-Item Cert:\LocalMachine\My\THUMBPRINT
$spki = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::Create().ComputeHash($cert.GetPublicKey()))
$pin = "sha256/$spki"

# Use with list-gen
.\list-gen.ps1 -Url https://example.com/files/ -CertificatePins $pin
```

Or programmatically:
```powershell
Invoke-ListGen -Urls @('https://example.com/files/') -NetworkParams @{
    CertificatePins = @('sha256/...')
}
```

### TLS Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ValidateCertificate` | Validate server certificate chain | `$true` |
| `-NoCertificateValidation` | **DISABLE** validation (TEST ONLY!) | `$false` |
| `-CertificatePins` | SPKI SHA256 pins for HPKP-style pinning | `@()` |

**⚠️ NEVER use `-NoCertificateValidation` in production.** It emits a prominent warning and is only for testing against self-signed certificates.

### Security Fixes from v2.x

| v2.x Issue | v3.0 Fix |
|------------|----------|
| `Invoke-Expression` on remote logging module | Bundled local `lib/logging.ps1`, optional secure download with SHA256 |
| No TLS validation / certificate pinning | Full validation + SPKI pinning via `Set-NetworkConfig` |
| Self-overwrite installation | Removed; explicit install via `Copy-Item` to module path |
| Hardcoded Windows paths | Cross-platform `$HOME`/`$env:XDG_*` resolution |
| Swallowed exceptions | Comprehensive try/catch, early logging init, no silent failures |
| Global scope pollution | Module-scoped variables, proper `Export-ModuleMember` |
| `Write-Host` abuse | Structured logging via `Write-Log`, `Write-Verbose`, `Write-Output` |

---

## Architecture

```
URL-list-generator/
├── list-gen.psd1          # Module manifest
├── list-gen.psm1          # Root module (loads nested modules, exports Invoke-ListGen)
├── list-gen.ps1           # Thin CLI entry point (~150 lines)
├── lib/
│   ├── logging.ps1        # Local logging module (zero deps, no IEX)
│   ├── network.ps1        # HTTP with retry, TLS, pinning
│   ├── url.ps1            # URL normalization & extraction
│   ├── input.ps1          # Input parsing (file, CLI, interactive)
│   └── output.ps1         # Output file handling, naming, results
├── tests/
│   └── list-gen.tests.ps1 # Pester unit tests
└── README.md
```

### Design Principles

1. **Security First** — No `Invoke-Expression`, bundled dependencies, TLS validation, pinning
2. **Modularity** — Single-responsibility lib modules, testable in isolation
3. **Cross-Platform** — No Windows-only paths/cmdlets, uses .NET APIs
4. **Observability** — Structured logging, WhatIf support, pipeline objects
5. **Resilience** — Retries, timeouts, redirect handling, directory validation
6. **Standards** — `CmdletBinding`, parameter validation, `Set-StrictMode`, JSDoc-style help

---

## Testing

```powershell
# Install Pester if needed
Install-Module Pester -Force -Scope CurrentUser

# Run all tests
Invoke-Pester tests/list-gen.tests.ps1 -Output Detailed

# Run specific describe block
Invoke-Pester tests/list-gen.tests.ps1 -Filter "Normalize-Url"

# Run with code coverage (requires Pester 5.4+)
Invoke-Pester tests/list-gen.tests.ps1 -CodeCoverage lib/*.ps1
```

---

## Configuration

### Network Defaults (via `Set-NetworkConfig`)

```powershell
Set-NetworkConfig `
    -TimeoutSec 60 `
    -MaxRetries 3 `
    -BaseDelayMs 1000 `
    -MaxDelayMs 30000 `
    -JitterPercent 0.1 `
    -FollowRedirects $true `
    -MaxRedirects 10 `
    -ValidateCertificate $true
```

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `LIST_GEN_LOG_LEVEL` | Default log level (DEBUG/INFO/WARN/ERROR) |
| `XDG_DOWNLOAD_DIR` | Linux download directory override |
| `XDG_STATE_HOME` | Linux log directory base |
| `XDG_DATA_HOME` | Linux log directory fallback |

---

## Examples

### Bulk Process from File

```powershell
# urls.txt contains one URL per line
.\list-gen.ps1 -InputFile urls.txt -OutputDir ~/bulk-output -LogLevel INFO
```

### With Certificate Pinning (Production)

```powershell
$pins = @(
    'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
)
.\list-gen.ps1 -Url https://internal.example.com/files/ -CertificatePins $pins
```

### Programmatic Batch Processing

```powershell
$results = Invoke-ListGen -InputFile 'sites.json' -OutputDir '~/archive' -LogLevel 'WARN'
$failed = $results | Where-Object { -not $_.Success }
if ($failed) {
    $failed | ForEach-Object { Write-Error "$($_.SourceUrl): $($_.Error)" }
    exit 1
}
```

### Interactive Mode

```powershell
.\list-gen.ps1
# Enter URLs or file paths, one per line
# Empty line to finish
```

### Safe Preview

```powershell
.\list-gen.ps1 -Url https://example.com/files/ -WhatIf
# WhatIf: Would process 1 directory URLs:
#   - https://example.com/files/
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Output directory not writable" | Check permissions; use `-OutputDir` with a writable path |
| "Certificate validation failed" | Add `-CertificatePins` with correct SPKI, or fix server cert |
| "No files found in directory" | Server may not serve directory listings; try `/index.html` |
| "Failed to retrieve directory listing" | Check network, firewall, URL correctness; increase `-TimeoutSec` |
| "Module not found" | Run from module directory or `Import-Module` with full path to `.psd1` |
| "PowerShell version too old" | Requires PowerShell 7.0+ (`pwsh --version`) |

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass: `Invoke-Pester`
5. Follow the existing code style (StrictMode, CmdletBinding, structured logging)
6. Submit a PR

### Code Standards

- `Set-StrictMode -Version Latest` in every file
- Advanced functions with `[CmdletBinding()]` and `[Parameter()]`
- Parameter validation via `[ValidateSet()]`, `[ValidateRange()]`, `[ValidateNotNullOrEmpty()]`
- Structured logging via `Write-Log` (not `Write-Host`)
- Pipeline output via `PSCustomObject` (not `Write-Output` strings)
- JSDoc-style `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` help
- Error handling: try/catch with `Write-ErrorLog` and meaningful context

---

## Changelog

### v3.0.0 (2025) — Complete Security-First Rewrite

- **Security**: Eliminated all `Invoke-Expression`; bundled local logging; optional secure download with SHA256
- **Architecture**: Monolith → proper module (`list-gen.psd1`, `lib/`, `tests/`, thin entry point)
- **TLS**: Full certificate validation + SPKI pinning via `Set-NetworkConfig`
- **Parameters**: Full `CmdletBinding`, multiple parameter sets, `-Help`/`-?`, `-WhatIf`/`-Confirm`
- **Error Handling**: Comprehensive try/catch, retry logic (3 attempts, exponential backoff), redirect following
- **Cross-Platform**: `$HOME`/`$env:XDG_*` paths; works on Windows, Linux, macOS
- **Logging**: Early init, JSONL structured logs, levels (DEBUG/INFO/WARN/ERROR), no swallowed exceptions
- **URL Handling**: `System.Uri`-based normalization (extensions, queries, fragments, auto-HTTPS)
- **Output**: Pipeline-friendly `PSCustomObject` results, collision-resistant naming (ms timestamp + hash)
- **Validation**: Output directory writability checks, parameter validation attributes
- **Testing**: Pester test suite (unit tests for all public functions)
- **Documentation**: Comprehensive README with installation, usage, examples, architecture

### v2.0.0 (Legacy)

- Single-file monolith with self-installation
- Remote logging module via `Invoke-Expression`
- No TLS validation, no retry logic
- Global scope pollution, `Write-Host` abuse
- Windows-only hardcoded paths

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Support

- **Issues**: [GitHub Issues](https://github.com/mytech-today-now/PowerShellScripts/issues)
- **Discussions**: [GitHub Discussions](https://github.com/mytech-today-now/PowerShellScripts/discussions)
- **Repository**: [mytech-today-now/PowerShellScripts](https://github.com/mytech-today-now/PowerShellScripts)

---

*Part of the [myTech.Today](https://mytech.today) PowerShell toolkit.*