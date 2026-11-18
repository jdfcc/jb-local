<#
  jb-local - self-hosted Windows installer

  One command (no download, no temp file):

      irm https://github.com/jdfcc/jb-local/releases/download/v1.0.1/install.ps1 | iex

  There is deliberately no param() block: Invoke-Expression cannot bind
  parameters. Options therefore come from

    * -File arguments, when the script was saved to disk, or
    * JB_LOCAL_* environment variables, when it is piped into iex:

      $env:JB_LOCAL_DRYRUN=1;      irm .../install.ps1 | iex
      $env:JB_LOCAL_SKIP_HIDING=1; irm .../install.ps1 | iex
      $env:JB_LOCAL_INSTALL_DIR='D:\jb-local'; irm .../install.ps1 | iex
      $env:JB_LOCAL_UNINSTALL=1;   irm .../install.ps1 | iex

  Env vars: JB_LOCAL_REPO JB_LOCAL_TAG JB_LOCAL_INSTALL_DIR JB_LOCAL_LAYOUT_ROOT
            JB_LOCAL_CONFIG_ROOT JB_LOCAL_PAYLOAD JB_LOCAL_NAME JB_LOCAL_EXPIRY
            JB_LOCAL_SKIP_HIDING JB_LOCAL_NO_VMOPTIONS JB_LOCAL_UNINSTALL
            JB_LOCAL_DRYRUN JB_LOCAL_NOELEVATE   (=1 to enable)

  Uninstall from disk:
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>


# --------------------------------------------------------------------- options

$__jbArgs = @($args)

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Cfg = [ordered]@{
    Repo         = 'jdfcc/jb-local'
    Tag          = 'v1.0.1'
    InstallDir   = (Join-Path $env:ProgramData 'jb-local')
    LayoutRoot   = (Join-Path $env:LOCALAPPDATA 'JetBrains')
    ConfigRoot   = (Join-Path $env:APPDATA 'JetBrains')
    LocalPayload = ''
    BaseUrl      = ''
    LicenseName  = 'local'
    Expiry       = '2099-12-31'
    Subject      = ''
    SkipHiding   = $false
    NoVmOptions  = $false
    Uninstall    = $false
    DryRun       = $false
    NoElevate    = $false
}

$envMap = [ordered]@{
    JB_LOCAL_REPO        = 'Repo'
    JB_LOCAL_TAG         = 'Tag'
    JB_LOCAL_INSTALL_DIR = 'InstallDir'
    JB_LOCAL_LAYOUT_ROOT = 'LayoutRoot'
    JB_LOCAL_CONFIG_ROOT = 'ConfigRoot'
    JB_LOCAL_PAYLOAD     = 'LocalPayload'
    JB_LOCAL_BASE_URL    = 'BaseUrl'
    JB_LOCAL_NAME        = 'LicenseName'
    JB_LOCAL_EXPIRY      = 'Expiry'
    JB_LOCAL_SKIP_HIDING = 'SkipHiding'
    JB_LOCAL_NO_VMOPTIONS= 'NoVmOptions'
    JB_LOCAL_UNINSTALL   = 'Uninstall'
    JB_LOCAL_DRYRUN      = 'DryRun'
    JB_LOCAL_NOELEVATE   = 'NoElevate'
}

foreach ($envName in $envMap.Keys) {
    $value = [Environment]::GetEnvironmentVariable($envName)
    if ([string]::IsNullOrEmpty($value)) { continue }
    $target = $envMap[$envName]
    if ($Cfg[$target] -is [bool]) {
        $Cfg[$target] = ($value -notin @('0', 'false', 'no', 'off'))
    } else {
        $Cfg[$target] = $value
    }
}

$argMap = @{
    repo = 'Repo'; tag = 'Tag'; installdir = 'InstallDir'; layoutroot = 'LayoutRoot'
    configroot = 'ConfigRoot'; localpayload = 'LocalPayload'; baseurl = 'BaseUrl'; licensename = 'LicenseName'
    name = 'LicenseName'; expiry = 'Expiry'; subject = 'Subject'
    skiphiding = 'SkipHiding'; novmoptions = 'NoVmOptions'; uninstall = 'Uninstall'
    dryrun = 'DryRun'; noelevate = 'NoElevate'
}
$switchNames = @('skiphiding', 'novmoptions', 'uninstall', 'dryrun', 'noelevate')

if ($__jbArgs.Count -gt 0) {
    for ($i = 0; $i -lt $args.Count; $i++) {
        $raw = [string]$__jbArgs[$i]
        if ($raw -notmatch '^--?(.+)$') { continue }
        $name = $Matches[1].ToLowerInvariant()
        if (-not $argMap.ContainsKey($name)) { continue }
        $target = $argMap[$name]
        if ($switchNames -contains $name) {
            $Cfg[$target] = $true
        } elseif ($i + 1 -lt $__jbArgs.Count -and ([string]$__jbArgs[$i + 1]) -notmatch '^--?[A-Za-z]') {
            $Cfg[$target] = [string]$__jbArgs[$i + 1]
            $i++
        }
    }
}

$Repo = $Cfg.Repo
$Tag = $Cfg.Tag
$InstallDir = $Cfg.InstallDir
$LayoutRoot = $Cfg.LayoutRoot
$ConfigRoot = $Cfg.ConfigRoot
$LocalPayload = $Cfg.LocalPayload
$BaseUrl = $Cfg.BaseUrl
$LicenseName = $Cfg.LicenseName
$Expiry = $Cfg.Expiry
$Subject = $Cfg.Subject
$SkipHiding = $Cfg.SkipHiding
$NoVmOptions = $Cfg.NoVmOptions
$Uninstall = $Cfg.Uninstall
$DryRun = $Cfg.DryRun
$NoElevate = $Cfg.NoElevate

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
function Get-AssetUrl([string]$name) {
    if ($Cfg.BaseUrl) { return ($Cfg.BaseUrl.TrimEnd('/') + '/' + $name) }
    return "https://github.com/$($Cfg.Repo)/releases/download/$($Cfg.Tag)/$name"
}

function Say([string]$msg) { Write-Host "[jb-local] $msg" }
function Step([string]$msg) { Write-Host "[jb-local] == $msg" -ForegroundColor Cyan }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    $selfUrl = Get-AssetUrl 'install.ps1'
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        # running from disk: re-run the same file with the same options
        $pairs = @(
            '-Repo', $Cfg.Repo, '-Tag', $Cfg.Tag, '-InstallDir', $Cfg.InstallDir,
            '-LayoutRoot', $Cfg.LayoutRoot, '-ConfigRoot', $Cfg.ConfigRoot,
            '-LicenseName', $Cfg.LicenseName, '-Expiry', $Cfg.Expiry
        )
        if ($Cfg.BaseUrl) { $pairs += @('-BaseUrl', $Cfg.BaseUrl) }
        if ($Cfg.LocalPayload) { $pairs += @('-LocalPayload', $Cfg.LocalPayload) }
        if ($Cfg.Subject) { $pairs += @('-Subject', $Cfg.Subject) }
        if ($Cfg.SkipHiding) { $pairs += '-SkipHiding' }
        if ($Cfg.NoVmOptions) { $pairs += '-NoVmOptions' }
        if ($Cfg.Uninstall) { $pairs += '-Uninstall' }
        if ($Cfg.DryRun) { $pairs += '-DryRun' }
        $quoted = ($pairs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $quoted"
    } else {
        # running from memory (irm | iex): fetch the same script again, elevated
        $pre = if ($Cfg.BaseUrl) { "`$env:JB_LOCAL_BASE_URL='$($Cfg.BaseUrl)'; " } else { '' }
        $argLine = "-NoProfile -ExecutionPolicy Bypass -Command `"$pre irm '$selfUrl' | iex`""
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
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
    if (-not $DryRun -and -not (Test-Path $backup)) { Copy-Item $File $backup -Force }
    $filtered = $content | Where-Object { $_ -notmatch '^\s*-javaagent:.*\.jar' }
    $lines = @($filtered) + $AgentLine
    if (-not $DryRun) {
        [IO.File]::WriteAllLines($File, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    Say "vmoptions patched: $File"
}

# --------------------------------------------------------------------------- main

if (-not (Test-Admin) -and -not $DryRun -and -not $NoElevate) { Invoke-Elevated; return }

$work = Join-Path $env:TEMP ("jb-local-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    if ($env:JB_LOCAL_DEBUG) { Say ("config: repo={0} tag={1} install={2} layout={3} config={4} dryrun={5} noelevate={6} base={7}" -f $Repo,$Tag,$InstallDir,$LayoutRoot,$ConfigRoot,$DryRun,$NoElevate,$BaseUrl) }
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
        $sumsUrl = Get-AssetUrl 'SHA256SUMS.txt'
        $zipUrl = Get-AssetUrl 'payload.zip'
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
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) { Say ("installer sha256: " + (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash) } else { Say "installer: running from memory (irm | iex)" }
    Say 'start the IDE and check Help > Register'
}
finally {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
} @__jbArgs
Remove-Variable __jbArgs -ErrorAction SilentlyContinue
