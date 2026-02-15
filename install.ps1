#Requires -Version 5.1
<#
.SYNOPSIS
    bz (beads_zig) installer for Windows.

.DESCRIPTION
    Downloads and installs the bz CLI tool from GitHub releases.

    One-liner install:
      irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1 | iex

    Or with options:
      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1))) -Version v0.1.7

.PARAMETER Version
    Specific version to install (e.g. v0.1.7). Default: latest.

.PARAMETER Dest
    Installation directory. Default: $env:LOCALAPPDATA\bz

.PARAMETER NoPath
    Skip adding install directory to user PATH.

.PARAMETER Verify
    Run self-test after install.

.PARAMETER Checksum
    Expected SHA256 checksum for verification.

.PARAMETER Quiet
    Suppress non-error output.

.PARAMETER Uninstall
    Remove bz and clean up PATH.

.EXAMPLE
    irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -Version v0.1.7 -Verify
#>

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Dest = "",
    [switch]$NoPath,
    [switch]$Verify,
    [string]$Checksum = "",
    [switch]$Quiet,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================
$Owner = "hotschmoe"
$Repo = "beads_zig"
$BinaryName = "bz.exe"
$InstallerVersion = "1.0.0"
$MaxRetries = 3
$DownloadTimeout = 120

if (-not $Dest) {
    $Dest = Join-Path $env:LOCALAPPDATA "bz"
}

# ============================================================================
# Output functions
# ============================================================================
function Write-Banner {
    if ($Quiet) { return }
    Write-Host ""
    Write-Host "+--------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|  bz installer                                    |" -ForegroundColor Green
    Write-Host "|  Local-first issue tracker (beads_zig)           |" -ForegroundColor DarkGray
    Write-Host "+--------------------------------------------------+" -ForegroundColor Blue
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    if ($Quiet) { return }
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    if ($Quiet) { return }
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
}

function Write-Detail {
    param([string]$Message)
    if ($Quiet) { return }
    Write-Host "    $Message" -ForegroundColor DarkGray
}

# ============================================================================
# Uninstall
# ============================================================================
function Invoke-Uninstall {
    Write-Banner
    Write-Step "Uninstalling bz..."

    $BinaryPath = Join-Path $Dest $BinaryName
    if (Test-Path $BinaryPath) {
        Remove-Item $BinaryPath -Force
        Write-Ok "Removed $BinaryPath"
    } else {
        Write-Warn "Binary not found at $BinaryPath"
    }

    # Remove from user PATH
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -and $UserPath.Contains($Dest)) {
        $NewPath = ($UserPath.Split(";") | Where-Object { $_ -ne $Dest -and $_ -ne "" }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        Write-Step "Removed $Dest from user PATH"
    }

    # Remove install directory if empty
    if ((Test-Path $Dest) -and -not (Get-ChildItem $Dest)) {
        Remove-Item $Dest -Force
        Write-Step "Removed empty directory $Dest"
    }

    Write-Ok "bz uninstalled successfully"
    exit 0
}

if ($Uninstall) {
    Invoke-Uninstall
}

# ============================================================================
# Version resolution
# ============================================================================
function Get-LatestVersion {
    $ApiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/latest"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $Headers = @{ "Accept" = "application/vnd.github.v3+json" }
            $Response = Invoke-RestMethod -Uri $ApiUrl -Headers $Headers -TimeoutSec 30
            $Tag = $Response.tag_name
            if ($Tag -match "^v\d") {
                return $Tag
            }
        } catch {
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds 2
            }
        }
    }

    throw "Could not resolve latest version. Try specifying -Version v0.1.7"
}

# ============================================================================
# Download with retry
# ============================================================================
function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $DownloadTimeout -UseBasicParsing
            $ProgressPreference = "Continue"
            return $true
        } catch {
            if ($attempt -lt $MaxRetries) {
                Write-Warn "Download failed (attempt $attempt/$MaxRetries), retrying in 3s..."
                Start-Sleep -Seconds 3
            }
        }
    }

    return $false
}

# ============================================================================
# Main
# ============================================================================
function Invoke-Install {
    Write-Banner

    # Architecture check
    $Arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { $null }
    if (-not $Arch) {
        Write-Err "Unsupported architecture. bz requires 64-bit Windows."
        exit 1
    }
    Write-Step "Platform: Windows $Arch"

    # Create install directory
    if (-not (Test-Path $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }
    Write-Step "Install directory: $Dest"

    # Resolve version
    if (-not $Version) {
        Write-Step "Resolving latest version..."
        $Version = Get-LatestVersion
    }
    Write-Ok "Version: $Version"

    # Build download URL
    $AssetName = "bz-windows-$Arch.exe"
    $DownloadUrl = "https://github.com/$Owner/$Repo/releases/download/$Version/$AssetName"
    $ChecksumUrl = "$DownloadUrl.sha256"

    # Download binary
    Write-Step "Downloading bz $Version..."
    Write-Detail "Source: github.com/$Owner/$Repo"

    $TempDir = Join-Path $env:TEMP "bz-install-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        $TempBinary = Join-Path $TempDir $AssetName
        if (-not (Invoke-Download -Url $DownloadUrl -OutFile $TempBinary)) {
            Write-Err "Download failed. Check that a release exists for Windows at version $Version"
            Write-Detail "URL: $DownloadUrl"
            exit 1
        }
        Write-Ok "Downloaded $('{0:N1} MB' -f ((Get-Item $TempBinary).Length / 1MB))"

        # Checksum verification
        $ExpectedHash = ""
        if ($Checksum) {
            $ExpectedHash = $Checksum.Split(" ")[0]
        } else {
            Write-Step "Fetching checksum..."
            $TempChecksum = Join-Path $TempDir "checksum.sha256"
            if (Invoke-Download -Url $ChecksumUrl -OutFile $TempChecksum) {
                $ExpectedHash = (Get-Content $TempChecksum -Raw).Trim().Split(" ")[0]
                Write-Ok "Checksum fetched"
            } else {
                Write-Warn "Checksum not available, skipping verification"
            }
        }

        if ($ExpectedHash) {
            Write-Step "Verifying checksum..."
            $ActualHash = (Get-FileHash $TempBinary -Algorithm SHA256).Hash.ToLower()
            if ($ActualHash -ne $ExpectedHash.ToLower()) {
                Write-Err "Checksum mismatch!"
                Write-Detail "Expected: $ExpectedHash"
                Write-Detail "Got:      $ActualHash"
                exit 1
            }
            Write-Ok "Checksum verified"
        }

        # Install binary (atomic: copy to temp in dest, then rename)
        Write-Step "Installing binary..."
        $FinalPath = Join-Path $Dest $BinaryName
        $TempDest = "$FinalPath.tmp.$PID"

        Copy-Item $TempBinary $TempDest -Force
        if (Test-Path $FinalPath) {
            # Windows can't atomically replace a running exe, but bz shouldn't be
            # running during install. Try rename with fallback.
            $OldPath = "$FinalPath.old.$PID"
            try {
                Rename-Item $FinalPath $OldPath -Force
                Rename-Item $TempDest $FinalPath -Force
                Remove-Item $OldPath -Force -ErrorAction SilentlyContinue
            } catch {
                # Fallback: direct overwrite
                Remove-Item $FinalPath -Force -ErrorAction SilentlyContinue
                Rename-Item $TempDest $FinalPath -Force
            }
        } else {
            Rename-Item $TempDest $FinalPath -Force
        }
        Write-Ok "Installed to $FinalPath"

    } finally {
        # Clean up temp directory
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # PATH configuration
    if (-not $NoPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if (-not $UserPath -or -not $UserPath.Contains($Dest)) {
            Write-Step "Adding $Dest to user PATH..."
            $NewPath = if ($UserPath) { "$Dest;$UserPath" } else { $Dest }
            [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
            # Update current session PATH too
            $env:Path = "$Dest;$env:Path"
            Write-Ok "Added to user PATH"
            Write-Detail "Restart your terminal for PATH changes to take effect in new sessions"
        } else {
            Write-Ok "PATH already includes $Dest"
        }
    }

    # Verify installation
    if ($Verify) {
        Write-Step "Running self-test..."
        try {
            $FinalPath = Join-Path $Dest $BinaryName
            $VersionOutput = & $FinalPath --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Self-test passed: $VersionOutput"
            } else {
                Write-Warn "Self-test returned non-zero exit code (binary may still work)"
            }
        } catch {
            Write-Warn "Self-test failed: $_"
        }
    }

    # Summary
    if (-not $Quiet) {
        Write-Host ""
        Write-Ok "Installation complete!"
        Write-Host ""

        $InstalledVersion = "unknown"
        try {
            $FinalPath = Join-Path $Dest $BinaryName
            $InstalledVersion = & $FinalPath --version 2>&1
        } catch {}

        Write-Detail "Version:  $InstalledVersion"
        Write-Detail "Location: $(Join-Path $Dest $BinaryName)"
        Write-Host ""
        Write-Ok "Run 'bz --help' to get started"
        Write-Host ""
    }
}

Invoke-Install
