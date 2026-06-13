# list-gen v4.0.0 - Professional URL List Generator

A production-ready PowerShell module and CLI for generating, crawling, validating, and exporting URL lists.

## Features

- **Robust HTML Parsing**: Extract URLs from `href`, `src`, and custom attributes with proper regex escaping
- **Web Crawling**: Breadth-first/depth-first crawling with configurable concurrency, rate limiting, and depth control
- **Multiple Input Sources**: Single URLs, files (txt, CSV, JSON, XML), sitemaps, robots.txt, clipboard, stdin
- **URL Normalization**: RFC 3986 compliant normalization (lowercase scheme/host, default port removal, dot-segment removal, query param sorting)
- **Validation**: Syntactic validation (RFC 3986) with optional reachability checking via HEAD requests
- **Robots.txt Support**: Automatic parsing and respect for crawl-delay, disallow/allow rules, and sitemap discovery
- **Flexible Export**: CSV, JSON, JSONL, XML, TXT, HTML, Sitemap XML, Excel, Markdown
- **Cross-Platform**: PowerShell 5.1+ (Windows) and PowerShell 7+ (Windows/Linux/macOS)
- **Structured Logging**: Leveled logging (Debug/Verbose/Info/Warning/Error/Critical) with console and file output
- **Zero Dependencies**: Pure PowerShell with .NET framework APIs only

## Installation

```powershell
# Clone the repository
git clone https://github.com/mytech-today-now/URL-list-generator.git
cd URL-list-generator/v.4

# Import the module
Import-Module ./list-gen.psd1

# Or run the CLI directly
.\list-gen.ps1 -Source 'https://example.com'
```

## Quick Start

### Extract URLs from a webpage
```powershell
.\list-gen.ps1 -Source 'https://example.com' -OutputPath './urls.csv'
```

### Crawl a site recursively
```powershell
.\list-gen.ps1 -Source 'https://blog.example.com' -Crawl -MaxDepth 2 -MaxUrls 500 -Format Json
```

### Process a sitemap
```powershell
.\list-gen.ps1 -Source 'sitemap:https://example.com/sitemap.xml' -Format Sitemap -OutputPath './sitemap.xml'
```

### Validate URLs from a file
```powershell
.\list-gen.ps1 -Source './urls.txt' -CheckReachability -Format Jsonl -OutputPath './validated.jsonl'
```

### Pipeline usage
```powershell
Get-Content urls.txt | .\list-gen.ps1 -Source stdin -Crawl -MaxDepth 1 -Format Csv -OutputPath ./results.csv
```

## Module Functions

| Function | Description |
|----------|-------------|
| `Get-UrlList` | Extract URLs from HTML content |
| `Invoke-UrlCrawl` | Crawl websites recursively |
| `Export-UrlList` | Export URLs to various formats |
| `ConvertTo-AbsoluteUrl` | Resolve relative URLs |
| `Test-UrlValid` | Validate URLs (syntax + optional reachability) |
| `Select-UrlPattern` | Filter URLs by wildcard/regex |
| `Get-UrlInput` | Read URLs from various sources |
| `Get-SitemapUrls` | Extract URLs from sitemaps |
| `Fetch-Page` | Fetch web page content |

## Examples

### Basic extraction with custom attributes
```powershell
$html = Invoke-WebRequest -Uri 'https://example.com' -UseBasicParsing
$urls = Get-UrlList -Html $html.Content -BaseUrl 'https://example.com' -Attributes @('href','src','data-src')
$urls | Export-UrlList -Path './extracted.csv' -Format Csv
```

### Crawl with progress and custom filter
```powershell
$results = Invoke-UrlCrawl -StartUrl 'https://docs.microsoft.com' -MaxDepth 2 -MaxUrls 1000 `
    -Pattern '*powershell*' -MaxConcurrent 3 -RateLimitMs 200 `
    -OnProgress { param($c,$t,$u,$d) Write-Host "[$c/$t] Depth $d: $u" } `
    -OnUrlDiscovered { param($u,$d,$s) Write-Verbose "Found: $u (from $s)" }
$results | Export-UrlList -Path './mspowershell.json' -Format Json
```

### URL validation pipeline
```powershell
$urls = Get-Content '.\input-urls.txt'
$validated = $urls | ForEach-Object { Test-UrlValid -Url $_ -CheckReachability -TimeoutSec 10 }
$validated | Where-Object IsValid | Export-UrlList -Path '.\valid.csv' -Format Csv
$validated | Where-Object { -not $_.IsValid } | Export-UrlList -Path '.\invalid.csv' -Format Csv
```

### Sitemap generation from crawl
```powershell
$crawl = Invoke-UrlCrawl -StartUrl 'https://mysite.com' -MaxDepth 3 -MaxUrls 2000
$crawl | Select-Object Url, @{N='LastMod';E={(Get-Date).ToString('yyyy-MM-dd')}}, @{N='ChangeFreq';E={'weekly'}}, @{N='Priority';E={0.8}} `
    | Export-UrlList -Path 'sitemap.xml' -Format Sitemap
```

## Configuration

### Logging
```powershell
# Enable debug logging to file
Set-LogConfig -Level Debug -EnableFile -FilePath '.\logs\list-gen.log' -MaxFileSizeMB 10 -MaxFiles 5

# Quiet mode (errors only)
Set-LogConfig -Level Error -EnableColors:$false
```

### Module Defaults
```powershell
$script:ModuleConfig.DefaultTimeoutSec = 30
$script:ModuleConfig.DefaultMaxDepth = 3
$script:ModuleConfig.DefaultMaxUrls = 1000
$script:ModuleConfig.DefaultRateLimitMs = 100
$script:ModuleConfig.MaxConcurrentRequests = 5
$script:ModuleConfig.DefaultUserAgent = 'list-gen/4.0.0 (+https://github.com/mytech-today-now/URL-list-generator)'
```

## CLI Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Source` | Input source (URL, file, sitemap:<url>, robots:<url>, clipboard, stdin) | Required |
| `-Crawl` | Enable recursive crawling | False |
| `-MaxDepth` | Maximum crawl depth | 3 |
| `-MaxUrls` | Maximum URLs to process | 1000 |
| `-MaxConcurrent` | Concurrent requests | 5 |
| `-RateLimitMs` | Delay between requests to same host (ms) | 100 |
| `-Pattern` | Wildcard filter (e.g., `*blog*`) | None |
| `-RegexPattern` | Regex filter | None |
| `-ExcludePattern` | Wildcard exclude pattern | None |
| `-AllowedDomains` | Comma-separated allowed domains | Same as start URLs |
| `-Format` | Output format | Csv |
| `-OutputPath` | Output file path | Auto |
| `-Properties` | Properties to export | All (*) |
| `-Validate` | Validate URLs syntactically | True |
| `-CheckReachability` | HTTP HEAD check | False |
| `-TimeoutSec` | Request timeout | 30 |
| `-UserAgent` | Custom User-Agent | list-gen/4.0.0 |
| `-Headers` | Additional headers (JSON or string) | {} |
| `-LogLevel` | Logging level | Info |
| `-LogFile` | Log file path | None |
| `-NoColor` | Disable colors | False |
| `-Progress` | Show progress bar | False |
| `-Quiet` | Suppress non-error output | False |

## Output Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| Csv | .csv | Comma-separated values |
| Json | .json | JSON array |
| Jsonl | .jsonl | JSON Lines (streaming) |
| Xml | .xml | XML document |
| Txt | .txt | Plain text (one URL per line) |
| Html | .html | Interactive HTML table |
| Sitemap | .xml | Sitemap protocol XML |
| Excel | .xlsx | Excel-compatible CSV |
| Markdown | .md | Markdown table |

## Regex Patterns (Internal)

The module uses pre-compiled, optimized regex patterns:

```powershell
# HREF extraction (fixed from v3 escaping bug)
(?xi) href \s* = \s* (?: "([^"]*)" | '([^']*)' | ([^\s>"']+) )

# SRC extraction
(?xi) src \s* = \s* (?: "([^"]*)" | '([^']*)' | ([^\s>"']+) )

# URL scheme detection
^([a-zA-Z][a-zA-Z0-9+.-]*):

# JavaScript/data: URL detection
^(?i)\s*(?:javascript|data|vbscript|about|blob):
```

## Error Handling

- All functions use `try/catch` with structured logging
- Network requests have configurable timeouts and retry logic
- Invalid URLs are logged and skipped (not thrown)
- `ErrorActionPreference = 'Stop'` ensures errors bubble up

## Performance

- Pre-compiled regex patterns with caching
- HttpClient connection pooling (PS 7+)
- Streaming export for large datasets
- Configurable concurrency and rate limiting
- Memory-efficient HashSet for deduplication

## Requirements

- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (Cross-platform)
- .NET Framework 4.7.2+ / .NET 6.0+
- Network access for crawling/validation

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## Changelog

### v4.0.0 (2024)
- Complete rewrite with modular architecture
- Fixed critical regex escaping bug in URL extraction
- Added robust HTML parsing with multiple attribute support
- Implemented full crawling engine with concurrency control
- Added sitemap and robots.txt support
- Multiple export formats with streaming
- Structured logging with file rotation
- Cross-platform compatibility (PS 5.1+ / 7+)
- Comprehensive parameter validation and error handling
- Type-safe output objects with C# definitions

### v3.x (Legacy)
- Single-file monolithic script
- Known regex escaping bug (fixed in v4)
- Limited error handling
- Basic CSV export only