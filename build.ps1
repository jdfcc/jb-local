<#
  build.ps1 - builds dist/payload.zip + SHA256SUMS.txt

  Requirements: a JDK 8+ on PATH, in JAVA_HOME, or pass -Jdk <dir>.
#>
[CmdletBinding()]
param(
    [string]$Jdk = '',
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$build = Join-Path $root 'build'
$classes = Join-Path $build 'classes'

function Find-Jdk {
    if ($Jdk) { return $Jdk }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) { return $env:JAVA_HOME }
    $c = Get-Command javac.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path (Split-Path $c.Source -Parent) -Parent) }
    foreach ($p in @('D:\jdk8u202', 'C:\Program Files\Java\latest', 'C:\Program Files\Eclipse Adoptium\jdk-17')) {
        if (Test-Path (Join-Path $p 'bin\javac.exe')) { return $p }
    }
    throw 'no JDK found: pass -Jdk C:\path\to\jdk'
}

$jdkHome = Find-Jdk
$javac = Join-Path $jdkHome 'bin\javac.exe'
$jarTool = Join-Path $jdkHome 'bin\jar.exe'
Write-Host "[build] jdk: $jdkHome"

Remove-Item $build, $OutDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $classes, $OutDir | Out-Null

$javacVersion = (& $javac -version 2>&1 | Out-String)
Write-Host "[build] $($javacVersion.Trim())"
if ($javacVersion -match 'javac\s+1\.8') {
    $releaseArgs = @('-source', '8', '-target', '8')
} else {
    $releaseArgs = @('--release', '8')
}

$sources = Get-ChildItem (Join-Path $root 'src') -Filter *.java | ForEach-Object { $_.FullName }
& $javac @releaseArgs -encoding UTF-8 -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

$manifest = Join-Path $build 'MANIFEST.MF'
Set-Content -Path $manifest -Value "Manifest-Version: 1.0`r`nMain-Class: Mint`r`n" -Encoding ASCII -NoNewline
$mintJar = Join-Path $build 'mint.jar'
& $jarTool cfm $mintJar $manifest -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
Write-Host "[build] mint.jar: $((Get-Item $mintJar).Length) bytes"

# payload staging
$stage = Join-Path $build 'payload'
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'config'), (Join-Path $stage 'plugins') | Out-Null
Copy-Item (Join-Path $root 'payload\ja-netfilter.jar') $stage -Force
Copy-Item $mintJar $stage -Force
Copy-Item (Join-Path $root 'payload\config\*') (Join-Path $stage 'config') -Force
Copy-Item (Join-Path $root 'payload\plugins\*.jar') (Join-Path $stage 'plugins') -Force
Set-Content -Path (Join-Path $stage 'VERSION') -Value $javacVersion.Trim() -Encoding ASCII

$zip = Join-Path $OutDir 'payload.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host "[build] payload.zip: $((Get-Item $zip).Length) bytes"

Copy-Item (Join-Path $root 'scripts\install.ps1') $OutDir -Force
Copy-Item (Join-Path $root 'scripts\install.sh') $OutDir -Force

$sums = foreach ($f in (Get-ChildItem $OutDir -File | Sort-Object Name)) {
    '{0}  {1}' -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $f.Name
}
$sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
Set-Content -Path $sumsPath -Value ($sums -join "`n") -Encoding ASCII -NoNewline

Write-Host "[build] dist:"
Get-ChildItem $OutDir -File | ForEach-Object { Write-Host ("  {0,-20} {1,10}" -f $_.Name, $_.Length) }
Write-Host "[build] SHA256SUMS.txt:"
Get-Content $sumsPath | ForEach-Object { Write-Host "  $_" }
