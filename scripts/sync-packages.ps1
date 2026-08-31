[CmdletBinding()]
param(
    [string] $DistributionName,
    [string] $UbuntuRelease,
    [string] $ConfigPath,
    [string] $ExpectedUser,
    [string] $ExpectedHostname,
    [string] $ExpectedVhdSize
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'WslTools.psm1') -Force
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config.psd1' }
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile $resolvedConfigPath
if (-not (Test-WslConfiguration $config)) { throw "Invalid WSL configuration: $resolvedConfigPath" }
$selectedImage = Resolve-WslImageSelection -Configuration $config -Selection $UbuntuRelease
$UbuntuRelease = $selectedImage.UbuntuRelease
if (-not $DistributionName) { $DistributionName = $selectedImage.DistributionName }
if (-not $ExpectedUser) { $ExpectedUser = $config.DefaultUser }
if (-not $ExpectedHostname) { $ExpectedHostname = $config.Hostname }
if (-not $ExpectedVhdSize) { $ExpectedVhdSize = $config.VhdSize }
if (-not (Test-WslDistributionName $DistributionName)) {
    throw "Invalid WSL distribution name '$DistributionName'."
}

$packages = @(Read-WslPackageList (Join-Path $repoRoot 'packages.txt'))
& wsl.exe --distribution $DistributionName --user root -- apt-get update
if ($LASTEXITCODE -ne 0) { throw 'apt-get update failed.' }
& wsl.exe --distribution $DistributionName --user root -- env DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends @packages
if ($LASTEXITCODE -ne 0) { throw 'Package installation failed.' }
& wsl.exe --distribution $DistributionName --user root -- apt-get clean
if ($LASTEXITCODE -ne 0) { throw 'apt-get clean failed.' }
try {
    & (Join-Path $PSScriptRoot 'verify.ps1') -DistributionName $DistributionName -ExpectedUbuntuRelease $UbuntuRelease -ExpectedUser $ExpectedUser -ExpectedHostname $ExpectedHostname -ExpectedVhdSize $ExpectedVhdSize -ConfigPath $resolvedConfigPath
} finally {
    & (Join-Path $PSScriptRoot 'capture-state.ps1') -DistributionName $DistributionName -ConfigPath $resolvedConfigPath
}
