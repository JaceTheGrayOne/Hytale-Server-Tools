# Hytale Server Updater v2.0.0
# --------------------------------------------------
#                   CHANGE LOG
# --------------------------------------------------
# v2.0.0 - [Added]
#          - Server-running check, staging & swap update, log file & summary,
#            download retries with ZIP validation, and safer failure cleanup.
# v1.0.0 - [Added]
#          - Initial release.
#
# --------------------------------------------------
#                   USAGE GUIDE
# --------------------------------------------------
# 1. Save this script as "somefilename.ps1" to a location.
#       I recommend "HytaleServerUpdate.ps1" in the same folder as your Hytale server.
# 2. Open File Explorer and go to that folder.
# 3. Click in the address bar at the top, type "powershell", and press Enter.
#       This will launch powershell in this directory
# 4. In the PowerShell window, run this command: .\Update.ps1
#       The ".\" is mandatory. It is what tells powershell to execute.
#       If you see a message about scripts being blocked, run this command first:
#       Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#       This allows local scripts to run for your user account.
# 5. The script will download and install the latest server files, reporting "Update Complete" when done.
#
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Destination,
    [switch]$ForceCleanup
)

$scriptDir = $PSScriptRoot
$logPath = Join-Path $scriptDir ("Update-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$script:ChangeSummary = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $Message
    Add-Content -Path $logPath -Value $line
}

function Resolve-ServerRoot {
    param(
        [string]$BaseDir,
        [string]$ExplicitDestination
    )

    if ($ExplicitDestination) {
        return (Resolve-Path -Path $ExplicitDestination).Path
    }

    $markers = @("HytaleServer.jar", "HytaleServer.aot")
    foreach ($m in $markers) {
        if (Test-Path (Join-Path $BaseDir $m)) {
            return $BaseDir
        }
    }

    foreach ($m in $markers) {
        $found = Get-ChildItem -Path $BaseDir -Recurse -Depth 3 -Filter $m -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.Directory.FullName
        }
    }

    throw "Unable to locate Hytale server. Pass -Destination to specify the server dir."
}

$serverRoot = Resolve-ServerRoot -BaseDir $scriptDir -ExplicitDestination $Destination
$downloader = Join-Path $scriptDir "hytale-downloader-windows-amd64.exe"
$downloaderTemp = $null

$tempRoot = Join-Path $env:TEMP ("hytale-update-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "game.zip"
$extractDir = Join-Path $tempRoot "game"
$versionFile = Join-Path $serverRoot "last_version.txt"
$stagingDir = Join-Path $serverRoot ".update_staging"
$backupDir = Join-Path $serverRoot (".update_backup_" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$success = $false

function Test-ServerRunning {
    param([string]$ServerDir)
    $jar = Join-Path $ServerDir "HytaleServer.jar"
    $aot = Join-Path $ServerDir "HytaleServer.aot"
    $processes = Get-CimInstance Win32_Process -Filter "Name='java.exe' or Name='javaw.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $processes) {
        $cmd = $p.CommandLine
        if (-not $cmd) { continue }
        if (($cmd -like "*$jar*") -or ($cmd -like "*$aot*") -or ($cmd -match 'HytaleServer\.jar') -or ($cmd -match 'HytaleServer\.aot')) {
            return $true
        }
    }
    return $false
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    if (Test-ServerRunning -ServerDir $serverRoot) {
        Write-Log "Server appears to be running. Stop the server before updating to avoid file locks or partial updates."
        throw "Server running. Aborting update."
    }

    if (-not (Test-Path $downloader)) {
        Write-Log "Updater not found, fetching latest..."
        $downloaderTemp = Join-Path $env:TEMP ("hytale-downloader-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $downloaderTemp | Out-Null
        $downloaderZip = Join-Path $downloaderTemp "hytale-downloader.zip"
        Invoke-WebRequest -Uri "https://downloader.hytale.com/hytale-downloader.zip" -OutFile $downloaderZip
        Expand-Archive -Path $downloaderZip -DestinationPath $downloaderTemp -Force

        $downloadedExe = Get-ChildItem -Path $downloaderTemp -Recurse -Filter "hytale-downloader-windows-amd64.exe" | Select-Object -First 1
        if (-not $downloadedExe) {
            throw "Downloader not found in archive."
        }
        Copy-Item -Path $downloadedExe.FullName -Destination $downloader -Force
    }

    $downloaded = $false
    $newVersion = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Log ("Downloading... (attempt $attempt of 3)")
        $lastProgressLen = 0
        $newVersion = $null
        & $downloader -download-path $zipPath 2>&1 | ForEach-Object {
            $line = $_.ToString()
            if (-not $newVersion -and $line -match 'version\s+([^)]+)\)') {
                $newVersion = $Matches[1].Trim()
            }
            if ($line -match '^\[' -and $line -match '%') {
                $pad = ""
                if ($lastProgressLen -gt $line.Length) {
                    $pad = " " * ($lastProgressLen - $line.Length)
                }
                Write-Host -NoNewline ("`r" + $line + $pad)
                $lastProgressLen = $line.Length
                return
            }

            if ($lastProgressLen -gt 0) {
                Write-Host ""
                $lastProgressLen = 0
            }
            Write-Host $line
            Add-Content -Path $logPath -Value $line
        }
        if ($lastProgressLen -gt 0) {
            Write-Host ""
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Log "Downloader exited with code $exitCode."
            Start-Sleep -Seconds 2
            continue
        }

        if (-not (Test-Path $zipPath)) {
            Write-Log "Download did not produce a ZIP. Retrying..."
            Start-Sleep -Seconds 2
            continue
        }

        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            $zip.Dispose()
        }
        catch {
            Write-Log "Downloaded ZIP appears corrupt. Retrying..."
            Start-Sleep -Seconds 2
            continue
        }

        $downloaded = $true
        break
    }

    if (-not $downloaded) {
        throw "Download failed after multiple attempts."
    }

    if ($newVersion) {
        $oldVersion = $null
        if (Test-Path $versionFile) {
            $oldVersion = Get-Content $versionFile -Raw
        }
        if ($newVersion -eq $oldVersion) {
            Write-Log "Up to date: ($newVersion). Exiting."
            return
        }
    }

    Write-Log "Extracting..."
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $serverDir = Join-Path $extractDir "Server"
    if (-not (Test-Path $serverDir)) {
        throw "Server folder not found: $serverDir"
    }

    $preserve = @(
        "mods",
        "universe",
        "logs",
        "config.json",
        "bans.json",
        "permissions.json",
        "whitelist.json",
        "auth.enc",
        ".hytale-downloader-credentials.json"
    )

    Write-Log "Updating..."
    if (Test-Path $stagingDir) {
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    Get-ChildItem -Path $serverDir -Force | ForEach-Object {
        if ($preserve -contains $_.Name) { return }

        $dest = Join-Path $stagingDir $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
        }
        else {
            Copy-Item -Path $_.FullName -Destination $dest -Force
        }
    }

    if (Test-Path $backupDir) {
        Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $backupDir | Out-Null

    Get-ChildItem -Path $stagingDir -Force | ForEach-Object {
        $dest = Join-Path $serverRoot $_.Name
        if (Test-Path $dest) {
            Move-Item -Path $dest -Destination (Join-Path $backupDir $_.Name) -Force
        }
        Move-Item -Path $_.FullName -Destination $dest -Force
        $script:ChangeSummary.Add($_.Name) | Out-Null
    }

    $assetsZip = Join-Path $extractDir "Assets.zip"
    if (Test-Path $assetsZip) {
        $assetsDestDir = $serverRoot
        $serverParent = Split-Path -Path $serverRoot -Parent
        if (Test-Path (Join-Path $serverRoot "Assets.zip")) {
            $assetsDestDir = $serverRoot
        }
        elseif ($serverParent -and (Test-Path (Join-Path $serverParent "Assets.zip"))) {
            $assetsDestDir = $serverParent
        }
        Copy-Item -Path $assetsZip -Destination (Join-Path $assetsDestDir "Assets.zip") -Force
        $script:ChangeSummary.Add("Assets.zip") | Out-Null
    }

    if ($newVersion) {
        Set-Content -Path $versionFile -Value $newVersion -NoNewline
    }

    $success = $true
    Write-Log "Update Complete."
    if ($script:ChangeSummary.Count -gt 0) {
        Write-Log ("Updated items: " + ($script:ChangeSummary -join ", "))
    }
}
finally {
    if ($success -or $ForceCleanup) {
        if ($downloaderTemp -and (Test-Path $downloaderTemp)) {
            Remove-Item -Path $downloaderTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Log "Update failed. Temp files kept for inspection:"
        Write-Log "Temp: $tempRoot"
        Write-Log "Staging: $stagingDir"
    }
}
