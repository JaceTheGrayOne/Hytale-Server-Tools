# Hytale Server Updater v2.1.0
# --------------------------------------------------
#                   CHANGE LOG
# --------------------------------------------------
# v2.1.0 - [Added]
#          - Improved PowerShell UX: -WhatIf/-Verbose/-Confirm support and Write-Progress instead of stdout.
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
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string]$Destination,
    [switch]$ForceCleanup
)

$scriptDir = $PSScriptRoot
$script:ChangeSummary = [System.Collections.Generic.List[string]]::new()
$script:LogEnabled = -not $WhatIfPreference

function Get-Dtg {
    return (Get-Date).ToString("ddMMMyy-HHmm", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
}

$logPath = Join-Path $scriptDir ("Update-" + (Get-Dtg) + ".log")

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Dtg
    $line = "[$timestamp] $Message"
    Write-Host $Message
    if ($script:LogEnabled) {
        Add-Content -Path $logPath -Value $line
    }
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
Write-Verbose ("Server root: " + $serverRoot)
$downloader = Join-Path $scriptDir "hytale-downloader-windows-amd64.exe"
$downloaderTemp = $null

$tempRoot = Join-Path $env:TEMP ("hytale-update-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "game.zip"
$extractDir = Join-Path $tempRoot "game"
$versionFile = Join-Path $serverRoot "last_version.txt"
$stagingDir = Join-Path $serverRoot ".update_staging"
$backupDir = Join-Path $serverRoot (".update_backup_" + (Get-Dtg))
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

if (-not $WhatIfPreference) {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
}

try {
    if (Test-ServerRunning -ServerDir $serverRoot) {
        Write-Log "Hytale Server is currently running. Stop the server before updating."
        throw "Server running. Exiting."
    }

    if (-not (Test-Path $downloader)) {
        Write-Log "Updater not found, fetching latest..."
        if (-not $PSCmdlet.ShouldProcess($downloader, "Install/update downloader")) {
            Write-Log "Downloader install skipped by user."
            if (-not $WhatIfPreference) {
                return
            }
        }
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
        if (-not $PSCmdlet.ShouldProcess($zipPath, "Download server package")) {
            Write-Log "Download skipped by user (dry run)."
            $downloaded = $true
            break
        }
        Write-Log ("Downloading... (attempt $attempt of 3)")
        Write-Progress -Id 1 -Activity "Downloading" -Status "Running downloader..." -PercentComplete 0
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
            if ($script:LogEnabled) {
                Add-Content -Path $logPath -Value $line
            }
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
            Write-Log "Download did not produce an archive. Retrying..."
            Start-Sleep -Seconds 2
            continue
        }

        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            $zip.Dispose()
        }
        catch {
            Write-Log "Downloaded archive is corrupt. Retrying..."
            Start-Sleep -Seconds 2
            continue
        }

        $downloaded = $true
        break
    }

    if (-not $downloaded -and -not $WhatIfPreference) {
        throw "Download failed."
    }
    Write-Progress -Id 1 -Activity "Downloading" -Completed

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
    if (-not $PSCmdlet.ShouldProcess($extractDir, "Extract server package")) {
        Write-Log "Extraction skipped by user (dry run)."
    }
    else {
        Write-Progress -Id 2 -Activity "Extracting" -Status "Expanding archive..." -PercentComplete 0
        New-Item -ItemType Directory -Path $extractDir | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        Write-Progress -Id 2 -Activity "Extracting" -Completed
    }

    $serverDir = Join-Path $extractDir "Server"
    if (-not $WhatIfPreference) {
        if (-not (Test-Path $serverDir)) {
            throw "Server not found: $serverDir"
        }
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
    if ($WhatIfPreference) {
        Write-Log "Dry run: would stage files from $serverDir into $stagingDir, backup into $backupDir, then swap into $serverRoot."
    }
    else {
        if (Test-Path $stagingDir) {
            if ($PSCmdlet.ShouldProcess($stagingDir, "Remove existing staging directory")) {
                Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not (Test-Path $stagingDir)) {
            if (-not $PSCmdlet.ShouldProcess($stagingDir, "Create staging directory")) {
                Write-Log "Staging directory creation skipped by user."
                return
            }
            New-Item -ItemType Directory -Path $stagingDir | Out-Null
        }

        $updateItems = Get-ChildItem -Path $serverDir -Force | Where-Object { $preserve -notcontains $_.Name }
        $totalStage = $updateItems.Count
        $stageIndex = 0
        foreach ($item in $updateItems) {
            $stageIndex++
            $percent = if ($totalStage -gt 0) { [int](($stageIndex / $totalStage) * 100) } else { 100 }
            Write-Progress -Id 3 -Activity "Staging files" -Status "$stageIndex of $totalStage" -PercentComplete $percent
            $dest = Join-Path $stagingDir $item.Name
            Write-Verbose ("Staging: " + $item.FullName)
            if ($PSCmdlet.ShouldProcess($dest, "Stage item")) {
                if ($item.PSIsContainer) {
                    Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
                }
                else {
                    Copy-Item -Path $item.FullName -Destination $dest -Force
                }
            }
        }
        Write-Progress -Id 3 -Activity "Staging files" -Completed

        if (Test-Path $backupDir) {
            if ($PSCmdlet.ShouldProcess($backupDir, "Remove existing backup directory")) {
                Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not (Test-Path $backupDir)) {
            if ($PSCmdlet.ShouldProcess($backupDir, "Create backup directory")) {
                New-Item -ItemType Directory -Path $backupDir | Out-Null
            }
        }

        $stagedItems = Get-ChildItem -Path $stagingDir -Force
        $totalApply = $stagedItems.Count
        $applyIndex = 0
        foreach ($item in $stagedItems) {
            $applyIndex++
            $percent = if ($totalApply -gt 0) { [int](($applyIndex / $totalApply) * 100) } else { 100 }
            Write-Progress -Id 4 -Activity "Applying update" -Status "$applyIndex of $totalApply" -PercentComplete $percent
            $dest = Join-Path $serverRoot $item.Name
            if (Test-Path $dest) {
                if ((Test-Path $backupDir) -and $PSCmdlet.ShouldProcess($dest, "Backup existing file")) {
                    Move-Item -Path $dest -Destination (Join-Path $backupDir $item.Name) -Force
                }
            }
            if ($PSCmdlet.ShouldProcess($dest, "Install updated file")) {
                Move-Item -Path $item.FullName -Destination $dest -Force
                $script:ChangeSummary.Add($item.Name) | Out-Null
            }
        }
        Write-Progress -Id 4 -Activity "Applying update" -Completed
    }

    $assetsZip = Join-Path $extractDir "Assets.zip"
    if ($WhatIfPreference -or (Test-Path $assetsZip)) {
        $assetsDestDir = $serverRoot
        $serverParent = Split-Path -Path $serverRoot -Parent
        if (Test-Path (Join-Path $serverRoot "Assets.zip")) {
            $assetsDestDir = $serverRoot
        }
        elseif ($serverParent -and (Test-Path (Join-Path $serverParent "Assets.zip"))) {
            $assetsDestDir = $serverParent
        }
        $assetsDest = Join-Path $assetsDestDir "Assets.zip"
        Write-Verbose ("Assets.zip destination: " + $assetsDest)
        if ($PSCmdlet.ShouldProcess($assetsDest, "Copy Assets.zip")) {
            Copy-Item -Path $assetsZip -Destination $assetsDest -Force
            $script:ChangeSummary.Add("Assets.zip") | Out-Null
        }
    }

    if ($newVersion) {
        if ($PSCmdlet.ShouldProcess($versionFile, "Write version file")) {
            Set-Content -Path $versionFile -Value $newVersion -NoNewline
        }
    }

    $success = $true
    Write-Log "Update Complete."
    if ($script:ChangeSummary.Count -gt 0) {
        Write-Log ("Updated items: " + ($script:ChangeSummary -join ", "))
    }
}
finally {
    if ((-not $WhatIfPreference) -and ($success -or $ForceCleanup)) {
        if ($downloaderTemp -and (Test-Path $downloaderTemp)) {
            if ($PSCmdlet.ShouldProcess($downloaderTemp, "Remove downloader temp directory")) {
                Remove-Item -Path $downloaderTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $tempRoot) {
            if ($PSCmdlet.ShouldProcess($tempRoot, "Remove update temp directory")) {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $stagingDir) {
            if ($PSCmdlet.ShouldProcess($stagingDir, "Remove staging directory")) {
                Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        if (-not $WhatIfPreference) {
            Write-Log "Update failed. Temp files preserved:"
            Write-Log "Temp: $tempRoot"
            Write-Log "Staging: $stagingDir"
        }
    }
}
