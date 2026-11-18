<#
  jb-local - self-hosted Windows installer

  Downloads a pinned release from YOUR GitHub repo, verifies its SHA256,
  installs the JVM agent, generates a local identity + power.conf on this
  machine, patches JetBrains vmoptions and writes <product>.key files.

  Nothing is fetched at run time except the release assets you pinned.
  No private key ships in the release: it is generated here, once.

  Usage (after downloading and checking the hash):
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo jdfcc/jb-local -Tag v1.0.0

  Uninstall:
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Repo = 'jdfcc/jb-local',
    [string]$Tag = 'v1.0.0',
    [string]$InstallDir = (Join-Path $env:ProgramData 'jb-local'),
    [string]$LayoutRoot = (Join-Path $env:LOCALAPPDATA 'JetBrains'),
    [string]$ConfigRoot = (Join-Path $env:APPDATA 'JetBrains'),
    [string]$LocalPayload = '',
    [string]$LicenseName = 'local',
    [string]$Expiry = '2099-12-31',
    [switch]$SkipHiding,
    [switch]$NoVmOptions,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Products = [ordered]@{
    'idea'      = 'II,PCWMP,PSI'
    'clion'     = 'CL,PSI,PCWMP'
    'phpstorm'  = 'PS,PCWMP,PSI'
    'goland'    = 'GO,PSI,PCWMP'
    'pycharm'   = 'PC,PSI,PCWMP'
    'webstorm'  = 'WS,PCWMP,PSI'
    'rider'     = 'RD,PDB,PSI,PCWMP'
    'datagrip'  = 'DB,PSI,PDB'
    'rubymine'  = 'RM,PCWMP,PSI'
    'appcode'   = 'AC,PCWMP,PSI'
    'dataspell' = 'DS,PSI,PDB,PCWMP'
    'rustrover' = 'RR,PSI,PCWP'
}

function Say([string]$msg) { Write-Host "[jb-local] $msg" }
function Step([string]$msg) { Write-Host "[jb-local] == $msg" -ForegroundColor Cyan }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Repo `"$Repo`" -Tag `"$Tag`" -InstallDir `"$InstallDir`" -LicenseName `"$LicenseName`" -Expiry `"$Expiry`""
    if ($SkipHiding) { $argLine += ' -SkipHiding' }
    if ($NoVmOptions) { $argLine += ' -NoVmOptions' }
    if ($Uninstall) { $argLine += ' -Uninstall' }
    if ($DryRun) { $argLine += ' -DryRun' }
    if ($LayoutRoot) { $argLine += " -LayoutRoot `"$LayoutRoot`"" }
    if ($ConfigRoot) { $argLine += " -ConfigRoot `"$ConfigRoot`"" }
    if ($LocalPayload) { $argLine += " -LocalPayload `"$LocalPayload`"" }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    exit 0
}

function Assert-Hash([string]$File, [string]$SumsPath) {
    $name = Split-Path $File -Leaf
    $expected = $null
    foreach ($line in Get-Content $SumsPath) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $name) {
            $expected = $Matches[1].ToLowerInvariant()
        }
    }
    if (-not $expected) { throw "no SHA256 entry for $name in SHA256SUMS.txt" }
    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA256 mismatch for ${name}: expected $expected got $actual" }
    Say "sha256 ok: $name $actual"
}

function Get-VerifiedDownload([string]$Url, [string]$Dest, [string]$SumsPath, [switch]$NoHash) {
    Say "download $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    if ($NoHash) { return }
    Assert-Hash -File $Dest -SumsPath $SumsPath
}

function Find-Java([string[]]$ProductHomes) {
    foreach ($prodHome in $ProductHomes) {
        $candidates = @(
            (Join-Path $prodHome 'jbr\bin\java.exe'),
            (Join-Path $prodHome 'jre64\bin\java.exe')
        )
        if ($prodHome -match '[\\/]Contents$') { $candidates += (Join-Path $prodHome 'jbr\Contents\Home\bin\java.exe') }
        foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        return (Join-Path $env:JAVA_HOME 'bin\java.exe')
    }
    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-JetBrainsLayout {
    $result = @()
    $roots = @($LayoutRoot)
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($dir in Get-ChildItem $root -Directory) {
            $key = $null
            foreach ($k in $Products.Keys) { if ($dir.Name.ToLowerInvariant().Contains($k)) { $key = $k; break } }
            if (-not $key) { continue }
            $configDir = Join-Path $ConfigRoot $dir.Name
            $prodHome = $null
            $homeFile = Join-Path $dir.FullName '.home'
            if (Test-Path $homeFile) {
                $candidate = (Get-Content $homeFile -Raw).Trim()
                if ($candidate) {
                    if (Test-Path (Join-Path $candidate 'bin')) { $prodHome = $candidate }
                    else {
                        $nested = Get-ChildItem $candidate -Directory -ErrorAction SilentlyContinue |
                            Where-Object { Test-Path (Join-Path $_.FullName 'bin') } | Select-Object -First 1
                        if ($nested) { $prodHome = $nested.FullName }
                    }
                }
            }
            $result += [pscustomobject]@{
                Key       = $key
                Codes     = $Products[$key]
                ConfigDir = $configDir
                Home      = $prodHome
                Label     = $dir.Name
            }
        }
    }
    return $result
}

function Set-VmOptions([string]$File, [string]$AgentLine) {
    $content = @(Get-Content -Path $File -ErrorAction Stop)
    $backup = "$File.bak-jblocal"
    if (-not (Test-Path $backup)) { Copy-Item $File $backup -Force }
    $filtered = $content | Where-Object { $_ -notmatch '^\s*-javaagent:.*\.jar' }
    $lines = @($filtered) + $AgentLine
    if (-not $DryRun) {
        [IO.File]::WriteAllLines($File, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    Say "vmoptions patched: $File"
}

# --------------------------------------------------------------------------- main

if (-not (Test-Admin) -and -not $DryRun -and -not $NoElevate) { Invoke-Elevated }

$work = Join-Path $env:TEMP ("jb-local-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Step 'layout'
    $layout = @(Get-JetBrainsLayout)
    if ($layout.Count -eq 0) { Say 'no JetBrains product found under %LOCALAPPDATA%\JetBrains'; }
    $layout | ForEach-Object { Say ("product {0,-22} home={1}" -f $_.Label, $_.Home) }

    if ($Uninstall) {
        Step 'uninstall'
        foreach ($p in $layout) {
            $keyFile = Join-Path $p.ConfigDir ($p.Key + '.key')
            if (Test-Path $keyFile) { if (-not $DryRun) { Remove-Item $keyFile -Force }; Say "removed $keyFile" }
            if (Test-Path $p.ConfigDir) {
                Get-ChildItem $p.ConfigDir -Filter '*.vmoptions' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $backup = "$($_.FullName).bak-jblocal"
                    if (Test-Path $backup) { if (-not $DryRun) { Move-Item $backup $_.FullName -Force }; Say "restored $($_.FullName)" }
                    else {
                        $kept = @(Get-Content $_.FullName | Where-Object { $_ -notmatch '^\s*-javaagent:.*\.jar' })
                        if (-not $DryRun) { [IO.File]::WriteAllLines($_.FullName, $kept, (New-Object System.Text.UTF8Encoding($false))) }
                        Say "cleaned $($_.FullName)"
                    }
                }
            }
            if ($p.Home -and (Test-Path (Join-Path $p.Home 'bin'))) {
                Get-ChildItem (Join-Path $p.Home 'bin') -Filter '*.vmoptions' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $backup = "$($_.FullName).bak-jblocal"
                    if (Test-Path $backup) { if (-not $DryRun) { Move-Item $backup $_.FullName -Force }; Say "restored $($_.FullName)" }
                }
            }
        }
        if (Test-Path $InstallDir) { if (-not $DryRun) { Remove-Item $InstallDir -Recurse -Force }; Say "removed $InstallDir" }
        Say 'done'
        return
    }

    Step 'release'
    $sums = Join-Path $work 'SHA256SUMS.txt'
    $zip = Join-Path $work 'payload.zip'
    if ($LocalPayload) {
        $src = (Resolve-Path $LocalPayload).Path
        $srcZip = Join-Path $src 'payload.zip'
        $srcSums = Join-Path $src 'SHA256SUMS.txt'
        if (-not (Test-Path $srcZip)) { throw "no payload.zip in $src" }
        if (-not (Test-Path $srcSums)) { throw "no SHA256SUMS.txt in $src" }
        Copy-Item $srcZip $zip -Force
        Copy-Item $srcSums $sums -Force
        Say "local payload: $src"
        Assert-Hash -File $zip -SumsPath $sums
    } else {
        $sumsUrl = "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt"
        $zipUrl = "https://github.com/$Repo/releases/download/$Tag/payload.zip"
        Get-VerifiedDownload -Url $sumsUrl -Dest $sums -SumsPath $sums -NoHash
        Get-VerifiedDownload -Url $zipUrl -Dest $zip -SumsPath $sums
    }

    Step 'extract'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage = Join-Path $work 'stage'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    foreach ($required in @('ja-netfilter.jar', 'mint.jar', 'config\ca-modulus.txt')) {
        if (-not (Test-Path (Join-Path $stage $required))) { throw "payload is missing $required" }
    }

    Step "install to $InstallDir"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'config') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'plugins') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'state') | Out-Null
        Copy-Item (Join-Path $stage 'ja-netfilter.jar') $InstallDir -Force
        Copy-Item (Join-Path $stage 'mint.jar') $InstallDir -Force
        Copy-Item (Join-Path $stage 'config\*') (Join-Path $InstallDir 'config') -Force
        Remove-Item (Join-Path $InstallDir 'config\power.conf') -Force -ErrorAction SilentlyContinue
        $pluginFilter = if ($SkipHiding) { { $_.Name -notin @('privacy.jar', 'hideme.jar') } } else { { $true } }
        Get-ChildItem (Join-Path $stage 'plugins') -Filter *.jar | Where-Object $pluginFilter |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $InstallDir 'plugins') -Force }
    }
    Say 'payload installed'

    $java = Find-Java @($layout | Where-Object { $_.Home } | ForEach-Object { $_.Home })
    if (-not $java) { throw 'no java.exe found: install a JetBrains product (its JBR is used) or set JAVA_HOME' }
    Say "java: $java"

    $agentJar = (Join-Path $InstallDir 'ja-netfilter.jar').Replace('\', '/')
    $agentLine = "-javaagent:$agentJar"

    Step 'licenses'
    $minted = 0
    foreach ($p in $layout) {
        if (-not (Test-Path $p.ConfigDir)) { Say "skip $($p.Label): no config dir"; continue }
        $licenseOut = Join-Path $p.ConfigDir ($p.Key + '.key')
        $mintArgs = @(
            '-cp', (Join-Path $InstallDir 'mint.jar'), 'Mint',
            '--dir', (Join-Path $InstallDir 'state'),
            '--power-conf', (Join-Path $InstallDir 'config\power.conf'),
            '--ca-modulus-file', (Join-Path $InstallDir 'config\ca-modulus.txt'),
            '--license-out', $licenseOut,
            '--license-name', $LicenseName,
            '--assignee', '',
            '--expiry', $Expiry,
            '--product-codes', $p.Codes,
            '--subject', ($p.Label + ' helper')
        )
        if ($DryRun) { Say ("dry-run: {0} {1}" -f $java, ($mintArgs -join ' ')); continue }
        & $java @mintArgs
        if ($LASTEXITCODE -ne 0) { throw "mint failed for $($p.Label)" }
        Say "key written: $licenseOut"
        $minted++
    }

    if (-not $NoVmOptions) {
        Step 'vmoptions'
        foreach ($p in $layout) {
            if ($p.Home -and (Test-Path (Join-Path $p.Home 'bin'))) {
                Get-ChildItem (Join-Path $p.Home 'bin') -Filter '*.vmoptions' -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Set-VmOptions $_.FullName $agentLine }
            }
            if (Test-Path $p.ConfigDir) {
                Get-ChildItem $p.ConfigDir -Filter '*.vmoptions' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Set-VmOptions $_.FullName $agentLine }
            }
        }
    }

    Step 'environment'
    foreach ($scope in @('User', 'Machine')) {
        foreach ($k in $Products.Keys) {
            $name = $k.ToUpperInvariant() + '_VM_OPTIONS'
            if ([Environment]::GetEnvironmentVariable($name, $scope)) {
                if (-not $DryRun) { [Environment]::SetEnvironmentVariable($name, $null, $scope) }
                Say "removed env $scope/$name"
            }
        }
    }

    Step 'done'
    Say "installed: $InstallDir"
    Say "keys: $minted"
    Say ("installer sha256: " + (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash)
    Say 'start the IDE and check Help > Register'
}
finally {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
