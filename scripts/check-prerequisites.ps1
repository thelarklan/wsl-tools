[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $UbuntuRelease,
    [string] $DistributionName
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'WslTools.psm1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'config.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile $resolvedConfigPath
if (-not (Test-WslConfiguration $config)) {
    throw "Invalid WSL configuration: $resolvedConfigPath"
}
$selectedImage = Resolve-WslImageSelection -Configuration $config -Selection $UbuntuRelease
if (-not $DistributionName) { $DistributionName = $selectedImage.DistributionName }
if (-not (Test-WslDistributionName $DistributionName)) { throw 'Invalid distribution name.' }

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($architecture -ne 'X64') {
    throw "The pinned AMD64 image requires an X64 Windows host; found '$architecture'."
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is not installed.'
}

$versionText = ((& wsl.exe --version 2>&1 | Out-String) -replace [char] 0, '')
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query the installed WSL version.'
}

$wslVersion = ConvertFrom-WslVersionText $versionText
if (-not $wslVersion) {
    throw 'A recent Store version of WSL is required. Run: wsl --update'
}

$minimumWsl = [version] $config.MinimumWsl
if ($wslVersion -lt $minimumWsl) {
    throw "WSL $minimumWsl or newer is required; found $wslVersion."
}

$wslHelp = ((& wsl.exe --help 2>&1 | Out-String) -replace [char] 0, '')
if (-not (Test-WslInstallHelp $wslHelp)) {
    throw 'This WSL version does not support the required custom-image installation options. Run: wsl --update'
}

Write-Host 'WSL prerequisites passed.' -ForegroundColor Green
Write-Host "  WSL version : $wslVersion"
Write-Host "  Architecture: AMD64 ($architecture)"
Write-Host "  Image       : $($selectedImage.FileName)"
Write-Host "  Distribution: $DistributionName"
