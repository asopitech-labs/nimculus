param(
    [string]$Version = "0.1.0",
    [string]$OutputDir = "dist/windows",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$output = Join-Path $repo $OutputDir
$stage = Join-Path $output "stage"
$installer = Join-Path $output "installer"
$exe = Join-Path $stage "nimculus.exe"
$nimcache = Join-Path $env:TEMP "nimculus-package-nimcache-$PID"

New-Item -ItemType Directory -Force -Path $stage, $installer | Out-Null
Remove-Item (Join-Path $installer "*") -Recurse -Force -ErrorAction SilentlyContinue
if (-not $SkipBuild) {
    Remove-Item (Join-Path $stage "*") -Recurse -Force -ErrorAction SilentlyContinue
    Push-Location $repo
    try {
        nimble install --depsOnly -y
        nim c --mm:arc -d:release --nimcache:$nimcache --path:src --out:$exe src/nimculus/main.nim
    } finally {
        Pop-Location
        Remove-Item $nimcache -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $exe)) { throw "Build output not found: $exe" }
if ((Get-Item $exe).Length -le 0) { throw "Build output is empty: $exe" }

$readme = Join-Path $repo "README.md"
if (Test-Path $readme) { Copy-Item $readme (Join-Path $stage "README.md") -Force }
$zip = Join-Path $output "Nimculus-$Version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal
if (-not (Test-Path $zip) -or (Get-Item $zip).Length -le 0) {
    throw "ZIP artifact was not created: $zip"
}

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $defaultIscc = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
    if (Test-Path $defaultIscc) { $iscc = Get-Item $defaultIscc }
}
if (-not $iscc) {
    throw "Inno Setup compiler ISCC.exe is required to create the Windows installer."
}
$iss = Join-Path $repo "packaging/windows/Nimculus.iss"
$isccPath = if ($iscc.Source) { $iscc.Source } else { $iscc.FullName }
& $isccPath $iss "/DAppVersion=$Version" "/DSourceDir=$stage" "/DOutputDir=$installer"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

$setups = @(Get-ChildItem -Path $installer -Filter "*.exe" -File)
if ($setups.Count -ne 1 -or $setups[0].Length -le 0) {
    throw "Expected exactly one non-empty installer in $installer"
}

Write-Host "Created $zip"
Write-Host "Created installer in $installer"
