<#
  smoke-test.ps1 - proves the packaged payload actually works

  Steps: unzip payload.zip -> mint an identity + license -> run Verify twice
  (with and without the agent) and assert the expected flip.

  Usage:  pwsh ./tests/smoke-test.ps1 -Dist ./dist [-Java <java.exe>]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dist,
    [string]$Java = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Find-Java {
    if ($Java) { return $Java }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { return (Join-Path $env:JAVA_HOME 'bin\java.exe') }
    foreach ($p in @(
            'D:\ide\IntelliJ IDEA 2026.3\jbr\bin\java.exe'
        )) { if (Test-Path $p) { return $p } }
    $c = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    throw 'no java found: pass -Java <path\to\java.exe>'
}

$dist = (Resolve-Path $Dist).Path
$zip = Join-Path $dist 'payload.zip'
if (-not (Test-Path $zip)) { throw "missing $zip" }

$javaExe = Find-Java
$work = Join-Path ([IO.Path]::GetTempPath()) ('jbl-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)
    $ca = (Get-Content (Join-Path $work 'config\ca-modulus.txt') -Raw).Trim()
    if (-not $ca) { throw 'payload has no ca-modulus.txt' }

    $classes = Join-Path $work '_verify'
    New-Item -ItemType Directory -Force -Path $classes | Out-Null

    # Verify.class ships inside the payload only if the build included it; compile it here
    $verifySrc = Join-Path $PSScriptRoot '..\src\Verify.java'
    if (Test-Path $verifySrc) {
        $javac = $null
        if ($env:JAVA_HOME) { $javac = Join-Path $env:JAVA_HOME 'bin\javac.exe' }
        if (-not $javac -or -not (Test-Path $javac)) {
            $c = Get-Command javac.exe -ErrorAction SilentlyContinue
            if ($c) { $javac = $c.Source }
        }
        if ($javac) {
            & $javac -d $classes $verifySrc
            if ($LASTEXITCODE -ne 0) { throw 'javac failed for Verify.java' }
        }
    }
    if (-not (Test-Path (Join-Path $classes 'Verify.class'))) { throw 'Verify.class not available (no JDK)' }

    $state = Join-Path $work 'state'
    & $javaExe -cp (Join-Path $work 'mint.jar') Mint `
        --dir $state `
        --power-conf (Join-Path $work 'config\power.conf') `
        --ca-modulus $ca `
        --license-out (Join-Path $work 'idea.key') `
        --license-name smoke --assignee '' --expiry 2099-12-31 --product-codes 'II,PCWMP,PSI'
    if ($LASTEXITCODE -ne 0) { throw 'mint failed' }

    $cert = Join-Path $state 'agent-cert.der'
    $key = Join-Path $work 'idea.key'

    $plain = & $javaExe -cp $classes Verify --cert $cert --ca-modulus $ca --key $key 2>&1
    $withAgent = & $javaExe "-javaagent:$(Join-Path $work 'ja-netfilter.jar')" -cp $classes Verify --cert $cert --ca-modulus $ca --key $key 2>&1

    $plainText = ($plain | Out-String)
    $agentText = ($withAgent | Out-String)
    Write-Host '--- without agent ---'
    Write-Host $plainText
    Write-Host '--- with agent ---'
    Write-Host $agentText

    $ok = $true
    if ($plainText -notmatch 'cert-signature-verifies-with-CA-key\s+=\s+false') { Write-Host 'FAIL: plain run should not verify with the CA key'; $ok = $false }
    if ($agentText -notmatch 'cert-signature-verifies-with-CA-key\s+=\s+true') { Write-Host 'FAIL: agent did not flip the CA-key verification'; $ok = $false }
    if ($agentText -notmatch 'license-signature-verifies\s+=\s+true') { Write-Host 'FAIL: license signature does not verify'; $ok = $false }
    if (-not $ok) { throw 'smoke test failed' }

    Write-Host 'SMOKE TEST PASSED'
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
