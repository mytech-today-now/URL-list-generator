<#
.SYNOPSIS
    Pester tests for list-gen module v3.0.0

.DESCRIPTION
    Unit tests for all public functions. Run with: Invoke-Pester tests/list-gen.tests.ps1

.NOTES
    Requires: Pester 5+
    Run from module root directory
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Import the module for testing
$moduleRoot = Split-Path $PSCommandPath -Parent | Split-Path -Parent
Import-Module -Name (Join-Path $moduleRoot 'list-gen.psd1') -Force -DisableNameChecking

BeforeAll {
    # Create temp directory for test files
    $testTempDir = Join-Path $env:TEMP "list-gen-tests-$([Guid]::NewGuid())"
    New-Item -Path $testTempDir -ItemType Directory -Force | Out-Null
    $script:TestTempDir = $testTempDir
}

AfterAll {
    # Cleanup temp directory
    if (Test-Path $script:TestTempDir) {
        Remove-Item -Path $script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Helper to create test input files
function New-TestInputFile {
    param([string]$Name, [string]$Content, [string]$Extension = '.txt')
    $path = Join-Path $script:TestTempDir "$Name$Extension"
    Set-Content -Path $path -Value $Content -Encoding UTF8
    return $path
}

Describe "Normalize-Url" {
    Context "Valid URLs with scheme" {
        It "Normalizes HTTPS URL with trailing slash" {
            $result = Normalize-Url -Url 'https://example.com/dir/'
            $result.AbsoluteUri | Should -Be 'https://example.com/dir/'
        }

        It "Adds trailing slash to directory URL without one" {
            $result = Normalize-Url -Url 'https://example.com/dir'
            $result.AbsoluteUri | Should -Be 'https://example.com/dir/'
        }

        It "Preserves file URLs without adding slash" {
            $result = Normalize-Url -Url 'https://example.com/file.txt'
            $result.AbsoluteUri | Should -Be 'https://example.com/file.txt'
        }

        It "Preserves query strings and fragments" {
            $result = Normalize-Url -Url 'https://example.com/path?query=1#frag'
            $result.AbsoluteUri | Should -Be 'https://example.com/path?query=1#frag'
        }
    }

    Context "Scheme-less URLs" {
        It "Assumes HTTPS by default" {
            $result = Normalize-Url -Url 'example.com/dir'
            $result.Scheme | Should -Be 'https'
            $result.AbsoluteUri | Should -Be 'https://example.com/dir/'
        }

        It "Uses HTTP when AssumeHttps is false" {
            $result = Normalize-Url -Url 'example.com/dir' -AssumeHttps $false
            $result.Scheme | Should -Be 'http'
        }
    }

    Context "Edge cases" {
        It "Handles URLs with port numbers" {
            $result = Normalize-Url -Url 'https://example.com:8080/dir'
            $result.Port | Should -Be 8080
        }

        It "Handles IPv6 addresses" {
            $result = Normalize-Url -Url 'https://[::1]/dir'
            $result.Host | Should -Be '::1'
        }

        It "Returns null for invalid URLs" {
            $result = Normalize-Url -Url 'not-a-url-at-all'
            $result | Should -BeNullOrEmpty
        }

        It "Handles complex paths with special characters" {
            $result = Normalize-Url -Url 'https://example.com/path with spaces/file.txt'
            $result.AbsolutePath | Should -Match '%20'
        }
    }
}

Describe "Test-IsFileUrl" {
    It "Returns true for known file extensions" {
        Test-IsFileUrl -Path '/path/file.txt' | Should -BeTrue
        Test-IsFileUrl -Path '/path/archive.tar.gz' | Should -BeTrue
        Test-IsFileUrl -Path '/path/image.png' | Should -BeTrue
        Test-IsFileUrl -Path '/path/document.pdf' | Should -BeTrue
    }

    It "Returns false for directory paths" {
        Test-IsFileUrl -Path '/path/' | Should -BeFalse
        Test-IsFileUrl -Path '/path' | Should -BeFalse
        Test-IsFileUrl -Path '/' | Should -BeFalse
    }

    It "Returns false for paths without extensions" {
        Test-IsFileUrl -Path '/path/unknown' | Should -BeFalse
    }
}

Describe "Resolve-RelativeUrl" {
    $baseUrl = 'https://example.com/dir/'

    It "Resolves simple relative paths" {
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl 'file.txt' | Should -Be 'https://example.com/dir/file.txt'
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl 'subdir/file.txt' | Should -Be 'https://example.com/dir/subdir/file.txt'
    }

    It "Handles parent directory references" {
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl '../file.txt' | Should -Be 'https://example.com/file.txt'
    }

    It "Preserves absolute URLs" {
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl 'https://other.com/file.txt' | Should -Be 'https://other.com/file.txt'
    }

    It "Returns null for fragment-only links" {
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl '#section' | Should -BeNullOrEmpty
    }

    It "Returns null for javascript: and mailto:" {
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl 'javascript:void(0)' | Should -BeNullOrEmpty
        Resolve-RelativeUrl -BaseUrl $baseUrl -RelativeUrl 'mailto:test@example.com' | Should -BeNullOrEmpty
    }
}

Describe "Should-IncludeUrl" {
    $baseUri = [System.Uri]'https://example.com/dir/'

    It "Includes files under base path" {
        $uri = [System.Uri]'https://example.com/dir/file.txt'
        Should-IncludeUrl -ResolvedUri $uri -BaseUri $baseUri | Should -BeTrue
    }

    It "Includes files in subdirectories" {
        $uri = [System.Uri]'https://example.com/dir/sub/file.txt'
        Should-IncludeUrl -ResolvedUri $uri -BaseUri $baseUri | Should -BeTrue
    }

    It "Excludes external hosts by default" {
        $uri = [System.Uri]'https://other.com/dir/file.txt'
        Should-IncludeUrl -ResolvedUri $uri -BaseUri $baseUri | Should -BeFalse
    }

    It "Includes external hosts when AllowExternal is true" {
        $uri = [System.Uri]'https://other.com/dir/file.txt'
        Should-IncludeUrl -ResolvedUri $uri -BaseUri $baseUri -AllowExternal $true | Should -BeTrue
    }

    It "Excludes directory links (ending with /)" {
        $uri = [System.Uri]'https://example.com/dir/subdir/'
        Should-IncludeUrl -ResolvedUrl $uri -BaseUri $baseUri | Should -BeFalse
    }

    It "Excludes parent/current directory references" {
        $uri = [System.Uri]'https://example.com/dir/../file.txt'
        Should-IncludeUrl -ResolvedUri $uri -BaseUri $baseUri | Should -BeFalse
    }
}

Describe "Parse-InputFile" {
    Context "Text files (.txt, .md, .rtf)" {
        It "Parses space-separated URLs" {
            $file = New-TestInputFile 'space' 'https://a.com https://b.com'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://a.com', 'https://b.com')
        }

        It "Parses comma-separated URLs" {
            $file = New-TestInputFile 'comma' 'https://a.com,https://b.com'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://a.com', 'https://b.com')
        }

        It "Parses newline-separated URLs" {
            $file = New-TestInputFile 'newline' "https://a.com`nhttps://b.com"
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://a.com', 'https://b.com')
        }

        It "Parses mixed separators" {
            $file = New-TestInputFile 'mixed' "https://a.com, https://b.com`nhttps://c.com"
            $result = Parse-InputFile -FilePath $file
            $result.Count | Should -Be 3
        }

        It "Ignores empty lines and whitespace" {
            $file = New-TestInputFile 'whitespace' "https://a.com`n`n   `nhttps://b.com"
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://a.com', 'https://b.com')
        }
    }

    Context "JSON files" {
        It "Parses array of strings" {
            $content = @('https://a.com', 'https://b.com') | ConvertTo-Json
            $file = New-TestInputFile 'json-array' $content '.json'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://a.com', 'https://b.com')
        }

        It "Parses single string" {
            $content = '"https://single.com"' | ConvertTo-Json
            $file = New-TestInputFile 'json-string' $content '.json'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://single.com')
        }

        It "Parses objects with 'url' property" {
            $content = @{ url = 'https://obj.com' } | ConvertTo-Json
            $file = New-TestInputFile 'json-obj' $content '.json'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://obj.com')
        }

        It "Parses objects with 'href' property" {
            $content = @{ href = 'https://href.com' } | ConvertTo-Json
            $file = New-TestInputFile 'json-href' $content '.json'
            $result = Parse-InputFile -FilePath $file
            $result | Should -Be @('https://href.com')
        }

        It "Parses array of objects" {
            $content = @(@{url='https://a.com'}, @{url='https://b.com'}) | ConvertTo-Json
            $file = New-TestInputFile 'json-obj-array' $content '.json'
            $result = Parse-InputFile -FilePath $file
            $result.Count | Should -Be 2
        }
    }

    Context "Error handling" {
        It "Throws for unsupported extensions" {
            $file = New-TestInputFile 'unsupported' 'content' '.xyz'
            { Parse-InputFile -FilePath $file } | Should -Throw
        }

        It "Throws for non-existent files" {
            { Parse-InputFile -FilePath 'C:\nonexistent\file.txt' } | Should -Throw
        }

        It "Throws for invalid JSON" {
            $file = New-TestInputFile 'bad-json' '{ invalid json' '.json'
            { Parse-InputFile -FilePath $file } | Should -Throw
        }
    }
}

Describe "Parse-CommandLineEntries" {
    It "Parses direct URLs" {
        $result = Parse-CommandLineEntries -Args @('https://a.com', 'https://b.com')
        $result | Should -Be @('https://a.com', 'https://b.com')
    }

    It "Parses file paths with supported extensions" {
        $file = New-TestInputFile 'cli-file' "https://fromfile.com"
        $result = Parse-CommandLineEntries -Args @($file)
        $result | Should -Be @('https://fromfile.com')
    }

    It "Ignores files with unsupported extensions" {
        $file = New-TestInputFile 'cli-unsup' "https://a.com" '.xyz'
        $result = Parse-CommandLineEntries -Args @($file)
        $result | Should -Be @($file)  # Treated as URL string
    }

    It "Handles mixed URLs and files" {
        $file = New-TestInputFile 'cli-mixed' "https://fromfile.com"
        $result = Parse-CommandLineEntries -Args @('https://direct.com', $file)
        $result.Count | Should -Be 2
    }
}

Describe "Get-DefaultOutputDir" {
    It "Returns a valid path" {
        $dir = Get-DefaultOutputDir
        $dir | Should -Not -BeNullOrEmpty
        Test-Path $dir | Should -BeTrue
    }
}

Describe "Get-DefaultLogDir" {
    It "Returns a valid path" {
        $dir = Get-DefaultLogDir
        $dir | Should -Not -BeNullOrEmpty
        # Directory may not exist yet, but path should be valid
    }
}

Describe "Test-OutputDirectory" {
    It "Validates existing writable directory" {
        $result = Test-OutputDirectory -Path $script:TestTempDir
        $result.Valid | Should -BeTrue
    }

    It "Creates missing directory when CreateIfMissing" {
        $newDir = Join-Path $script:TestTempDir 'new-subdir'
        $result = Test-OutputDirectory -Path $newDir -CreateIfMissing $true
        $result.Valid | Should -BeTrue
        Test-Path $newDir | Should -BeTrue
    }

    It "Fails for missing directory without CreateIfMissing" {
        $result = Test-OutputDirectory -Path 'C:\nonexistent\path' -CreateIfMissing $false
        $result.Valid | Should -BeFalse
    }
}

Describe "New-OutputFilePath" {
    It "Generates unique filenames with prefix, sanitized source, timestamp, and hash" {
        $path = New-OutputFilePath -SourceIdentifier 'https://example.com/dir/' -OutputDir $script:TestTempDir -Prefix 'test' -Extension '.txt'
        $path | Should -Match 'test-example_com_dir-\d{8}-\d{6}-\d{3}-[A-Za-z0-9]{8}\.txt'
    }

    It "Produces different paths for same source (due to timestamp/hash)" {
        $path1 = New-OutputFilePath -SourceIdentifier 'https://example.com/dir/' -OutputDir $script:TestTempDir
        Start-Sleep -Milliseconds 2
        $path2 = New-OutputFilePath -SourceIdentifier 'https://example.com/dir/' -OutputDir $script:TestTempDir
        $path1 | Should -Not -Be $path2
    }

    It "Sanitizes special characters in source" {
        $path = New-OutputFilePath -SourceIdentifier 'https://example.com/path with spaces?query=1#frag' -OutputDir $script:TestTempDir
        $path | Should -Not -Match '[?#\s]'
    }
}

Describe "Write-UrlListToFile" {
    It "Writes URLs to file, one per line" {
        $urls = @('https://a.com', 'https://b.com', 'https://c.com')
        $file = Join-Path $script:TestTempDir 'output.txt'
        $result = Write-UrlListToFile -Urls $urls -OutputPath $file
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 3
        (Get-Content $file) | Should -Be @('https://a.com', 'https://b.com', 'https://c.com')
    }

    It "Returns error for empty URL array" {
        $file = Join-Path $script:TestTempDir 'empty.txt'
        $result = Write-UrlListToFile -Urls @() -OutputPath $file
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'No URLs'
    }

    It "Creates parent directory if needed" {
        $urls = @('https://a.com')
        $file = Join-Path $script:TestTempDir 'newdir', 'output.txt'
        $result = Write-UrlListToFile -Urls $urls -OutputPath $file
        $result.Success | Should -BeTrue
        Test-Path $file | Should -BeTrue
    }
}

Describe "New-ProcessingResult" {
    It "Creates complete result object" {
        $result = New-ProcessingResult `
            -SourceUrl 'https://example.com/dir' `
            -NormalizedUrl ([System.Uri]'https://example.com/dir/') `
            -FileUrls @('https://example.com/dir/file1.txt', 'https://example.com/dir/file2.txt') `
            -OutputFile 'C:\output\list.txt' `
            -Success $true

        $result.SourceUrl     | Should -Be 'https://example.com/dir'
        $result.NormalizedUrl | Should -Be 'https://example.com/dir/'
        $result.FileCount     | Should -Be 2
        $result.FileUrls.Count | Should -Be 2
        $result.OutputFile    | Should -Be 'C:\output\list.txt'
        $result.Success       | Should -BeTrue
        $result.Timestamp     | Should -Not -BeNullOrEmpty
    }

    It "Creates error result" {
        $result = New-ProcessingResult -SourceUrl 'bad' -Success $false -ErrorMessage 'Failed'
        $result.Success | Should -BeFalse
        $result.Error   | Should -Be 'Failed'
    }
}

Describe "Initialize-Log and Write-Log" {
    It "Initializes logging and writes entries" {
        $logFile = Join-Path $script:TestTempDir 'test-log.jsonl'
        Initialize-Log -LogPath $logFile -MinLevel 'DEBUG'
        Write-Log -Level 'INFO' -Message 'Test message' -Context @{ key = 'value' }
        Write-Log -Level 'ERROR' -Message 'Error message' -Exception (New-Object System.Exception 'Test error')

        $lines = Get-Content $logFile
        $lines.Count | Should -Be 3  # Init + Info + Error

        $entry = $lines[1] | ConvertFrom-Json
        $entry.level   | Should -Be 'INFO'
        $entry.message | Should -Be 'Test message'
        $entry.context.key | Should -Be 'value'

        $entry = $lines[2] | ConvertFrom-Json
        $entry.level      | Should -Be 'ERROR'
        $entry.exception.type | Should -Be 'System.Exception'
    }

    It "Filters by log level" {
        $logFile = Join-Path $script:TestTempDir 'test-filter.jsonl'
        Initialize-Log -LogPath $logFile -MinLevel 'WARN'
        Write-Log -Level 'INFO' -Message 'Should not appear'
        Write-Log -Level 'WARN' -Message 'Should appear'

        $lines = Get-Content $logFile
        $lines.Count | Should -Be 2  # Init + Warn
    }
}

Describe "Set-NetworkConfig and Get-NetworkConfig" {
    It "Gets and sets configuration" {
        Set-NetworkConfig -TimeoutSec 30 -MaxRetries 5
        $config = Get-NetworkConfig
        $config.DefaultTimeoutSec | Should -Be 30
        $config.MaxRetries | Should -Be 5
    }

    It "Warns when SkipCertificateCheck used" {
        # This test just verifies no crash
        Set-NetworkConfig -SkipCertificateCheck
        $config = Get-NetworkConfig
        $config.ValidateCertificate | Should -BeFalse
    }
}

Describe "Invoke-ListGen (programmatic API)" {
    It "Returns empty array for no entries (WhatIf)" {
        $results = Invoke-ListGen -Urls @() -WhatIf
        $results | Should -Be @()
    }

    # Integration tests would require a test HTTP server
    # These are unit tests for the logic only
}

# Run tests if executed directly
if ($PSCommandPath -eq $MyInvocation.MyCommand.Path) {
    Invoke-Pester -ScriptBlock $ExecutionContext.InvokeCommand.GetScriptBlock($MyInvocation.MyCommand.Definition) -Output Detailed
}