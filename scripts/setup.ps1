[CmdletBinding()]
param(
    [string] $DistributionName,
    [string] $UserName,
    [Nullable[int]] $UserId,
    [string] $Hostname,
    [string] $VhdSize,
    [string] $ConfigPath,
    [string] $ImagePath,
    [string] $CacheDirectory = (Join-Path $env:LOCALAPPDATA 'wsl-images'),
    [switch] $NonInteractive,
    [switch] $Resume,
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'WslTools.psm1') -Force
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config.psd1' }
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile $resolvedConfigPath

function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]] $Arguments)
    & wsl.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Get-InstalledDistribution {
    $lines = @(& wsl.exe --list --quiet 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate WSL distributions.' }
    @($lines | ForEach-Object { ($_ -replace [char] 0, '').Trim() } | Where-Object { $_ })
}

function Read-Setting {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $DefaultValue
    )
    $answer = Read-Host "$Label [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultValue }
    return $answer.Trim()
}

if ($Resume -and $VerifyOnly) { throw '-Resume and -VerifyOnly cannot be used together.' }
if (-not (Test-WslConfiguration $config)) { throw "Invalid WSL configuration: $resolvedConfigPath" }
if (-not $DistributionName) { $DistributionName = $config.DistributionName }
if (-not $UserName) { $UserName = $config.DefaultUser }
if (-not $Hostname) { $Hostname = $config.Hostname }
if (-not $VhdSize) { $VhdSize = $config.VhdSize }

if (-not $NonInteractive -and -not $Resume -and -not $VerifyOnly) {
    if (-not $PSBoundParameters.ContainsKey('DistributionName')) {
        $DistributionName = Read-Setting -Label 'WSL distribution name' -DefaultValue $DistributionName
    }
    if (-not $PSBoundParameters.ContainsKey('UserName')) {
        $UserName = Read-Setting -Label 'Linux username' -DefaultValue $UserName
    }
    if (-not $PSBoundParameters.ContainsKey('Hostname')) {
        $Hostname = Read-Setting -Label 'Linux hostname' -DefaultValue $Hostname
    }
    if (-not $PSBoundParameters.ContainsKey('VhdSize')) {
        $VhdSize = Read-Setting -Label 'Maximum VHD size' -DefaultValue $VhdSize
    }
}

if (-not (Test-WslDistributionName $DistributionName)) { throw "Invalid WSL distribution name '$DistributionName'." }
if (-not (Test-LinuxUserName $UserName)) { throw "Invalid Linux username '$UserName'." }
if (-not (Test-WslHostName $Hostname)) { throw "Invalid hostname '$Hostname'." }
if (-not (Test-WslVhdSize $VhdSize)) { throw "Invalid VHD size '$VhdSize'." }
$packages = @(Read-WslPackageList (Join-Path $repoRoot 'packages.txt'))

& (Join-Path $PSScriptRoot 'check-prerequisites.ps1') -ConfigPath $resolvedConfigPath
$installed = @(Get-InstalledDistribution)
$exists = $installed -contains $DistributionName
if ($exists -and -not $Resume -and -not $VerifyOnly) {
    throw (Get-WslExistingDistributionMessage `
        -DistributionName $DistributionName `
        -UserName $UserName `
        -Hostname $Hostname `
        -VhdSize $VhdSize)
}
if ($Resume -and -not $exists) { throw "Distribution '$DistributionName' is not installed; there is nothing to resume." }
if ($VerifyOnly -and -not $exists) { throw "Distribution '$DistributionName' is not installed." }

$requestedUserId = if ($PSBoundParameters.ContainsKey('UserId')) { [int] $UserId } else { $null }
$currentUserId = $null
$usedUserIds = [Collections.Generic.List[int]]::new()
$targetPasswdLines = @()
if ($exists) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $targetPasswdLines = @(& wsl.exe --distribution $DistributionName --user root -- cat /etc/passwd 2>&1)
        $passwdExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($passwdExitCode -ne 0) {
        throw "Unable to inspect Linux user IDs in WSL distribution '$DistributionName'."
    }
    foreach ($passwdLine in $targetPasswdLines) {
        $fields = ([string] $passwdLine -replace [char] 0, '') -split ':'
        if ($fields.Count -lt 3 -or -not (Test-WslUserId $fields[2])) { continue }
        if ($fields[0] -ceq $UserName) { $currentUserId = [int] $fields[2] }
    }
}

if ($null -ne $currentUserId) {
    $resolvedUserId = Resolve-WslUserId -CurrentUserId $currentUserId -RequestedUserId $requestedUserId
} else {
    if ($exists -and $VerifyOnly) { throw "User '$UserName' does not exist in '$DistributionName'." }
    foreach ($distribution in $installed) {
        if ($distribution -eq $DistributionName) {
            $passwdLines = $targetPasswdLines
        } else {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $passwdLines = @(& wsl.exe --distribution $distribution --user root -- cat /etc/passwd 2>&1)
                $passwdExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($passwdExitCode -ne 0) {
                Write-Warning "Unable to inspect Linux user IDs in WSL distribution '$distribution'; ignoring it for UID allocation."
                continue
            }
        }
        foreach ($passwdLine in $passwdLines) {
            $fields = ([string] $passwdLine -replace [char] 0, '') -split ':'
            if ($fields.Count -ge 3 -and (Test-WslUserId $fields[2])) { $usedUserIds.Add([int] $fields[2]) }
        }
    }
    $resolvedUserId = Resolve-WslUserId -UsedUserIds $usedUserIds.ToArray() -RequestedUserId $requestedUserId
}

Write-Host "Linux UID: $resolvedUserId"

if ($VerifyOnly) {
    & (Join-Path $PSScriptRoot 'verify.ps1') -DistributionName $DistributionName -ExpectedUser $UserName -ExpectedUserId $resolvedUserId -ExpectedHostname $Hostname -ExpectedVhdSize $VhdSize -ConfigPath $resolvedConfigPath
    exit 0
}

if (-not $NonInteractive -and -not $Resume) {
    Write-Host ''
    Write-Host 'Installation plan:' -ForegroundColor Cyan
    Write-Host "  Distribution : $DistributionName"
    Write-Host '  Image        : Ubuntu 26.04 LTS AMD64'
    Write-Host "  Linux user   : $UserName (locked password, passwordless sudo)"
    Write-Host "  Linux UID    : $resolvedUserId (unique across inspected WSL distributions)"
    Write-Host "  Hostname     : $Hostname"
    Write-Host "  VHD maximum  : $VhdSize"
    $confirmation = Read-Host 'Continue? [y/N]'
    if ($confirmation -notmatch '^(y|yes)$') {
        Write-Host 'Cancelled. No changes were made.'
        exit 0
    }
}

if (-not $exists) {
    $image = $config.Images.AMD64
    if ($ImagePath) {
        $resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
    } else {
        New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
        $resolvedImage = Join-Path $CacheDirectory $image.FileName
        if (Test-Path -LiteralPath $resolvedImage) {
            $cachedHash = (Get-FileHash -LiteralPath $resolvedImage -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($cachedHash -ne $image.Sha256) {
                Write-Warning 'Removing an incomplete or invalid cached image.'
                Remove-Item -LiteralPath $resolvedImage -Force
            }
        }
        if (-not (Test-Path -LiteralPath $resolvedImage)) {
            $partial = "$resolvedImage.part"
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-Host "Downloading the pinned Ubuntu $($config.UbuntuRelease) WSL image..."
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $image.Url -OutFile $partial
                $partialHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($partialHash -ne $image.Sha256) { throw 'Downloaded image checksum mismatch.' }
                Move-Item -LiteralPath $partial -Destination $resolvedImage
            } catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                throw
            }
        }
    }

    $actualHash = (Get-FileHash -LiteralPath $resolvedImage -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $image.Sha256) { throw 'Ubuntu image checksum mismatch.' }

    Write-Host "Installing '$DistributionName' with a $VhdSize maximum VHD..."
    $installArguments = Get-WslInstallArguments -ImagePath $resolvedImage -DistributionName $DistributionName -VhdSize $VhdSize
    Invoke-Wsl -Arguments $installArguments
}

$provision = ConvertTo-BashLineEndings (Get-Content -Raw (Join-Path $PSScriptRoot 'provision.sh'))
$base64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($provision))
$quotedPackages = @($packages | ForEach-Object { "'$_'" }) -join ' '
$command = "printf '%s' '$base64' | base64 --decode | bash -s -- '$UserName' '$Hostname' '$resolvedUserId' $quotedPackages"

Write-Host "Provisioning '$UserName' (UID $resolvedUserId) and $($packages.Count) baseline packages..."
$provisioningCompleted = $false
try {
    Invoke-Wsl -Arguments @('--distribution', $DistributionName, '--user', 'root', '--', 'bash', '-lc', $command)
    $provisioningCompleted = $true
} finally {
    & wsl.exe --terminate $DistributionName
    $terminationExitCode = $LASTEXITCODE
    if ($terminationExitCode -ne 0) {
        if ($provisioningCompleted) {
            throw "Unable to terminate '$DistributionName'; wsl.exe exited with code $terminationExitCode."
        }
        Write-Warning "Provisioning failed and '$DistributionName' could not be terminated (exit $terminationExitCode)."
    }
}
try {
    & (Join-Path $PSScriptRoot 'verify.ps1') -DistributionName $DistributionName -ExpectedUser $UserName -ExpectedUserId $resolvedUserId -ExpectedHostname $Hostname -ExpectedVhdSize $VhdSize -ConfigPath $resolvedConfigPath
} finally {
    & (Join-Path $PSScriptRoot 'capture-state.ps1') -DistributionName $DistributionName -ConfigPath $resolvedConfigPath
}
Write-Host "Ubuntu is ready. Start it with: wsl ~ -d $DistributionName"
