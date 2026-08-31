[CmdletBinding()]
param(
    [string] $DistributionName,
    [string] $UbuntuRelease,
    [string] $UserName,
    [Nullable[int]] $UserId,
    [string] $Hostname,
    [string] $VhdSize,
    [string] $ConfigPath,
    [string] $ImagePath,
    [string] $CacheDirectory,
    [switch] $NonInteractive,
    [switch] $Resume,
    [switch] $VerifyOnly,
    [ValidateSet('Install', 'Update')]
    [string] $HostAction
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$modulePath = Join-Path $repoRoot 'scripts\WslTools.psm1'
$setupPath = Join-Path $repoRoot 'scripts\setup.ps1'
Import-Module $modulePath -Force

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentWslHostState {
    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslCommand) {
        return 'Absent'
    }

    $versionText = ((& wsl.exe --version 2>&1 | Out-String) -replace [char] 0, '')
    $versionExitCode = $LASTEXITCODE
    & wsl.exe --status 2>&1 | Out-Null
    $statusExitCode = $LASTEXITCODE
    $helpText = ((& wsl.exe --help 2>&1 | Out-String) -replace [char] 0, '')

    $virtualMachinePlatformEnabled = $false
    $restartPending = $false
    try {
        $virtualMachinePlatform = Get-CimInstance `
            -ClassName Win32_OptionalFeature `
            -Filter "Name='VirtualMachinePlatform'" `
            -ErrorAction Stop
        $virtualMachinePlatformEnabled = $virtualMachinePlatform.InstallState -eq 1
        $restartPending = Test-Path `
            -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    } catch {
        Write-Verbose "Unable to read Windows optional-feature state: $_"
    }

    $configurationPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $repoRoot 'config.psd1' }
    $resolvedConfigurationPath = (Resolve-Path -LiteralPath $configurationPath).Path
    $configuration = Import-PowerShellDataFile $resolvedConfigurationPath
    if (-not (Test-WslConfiguration $configuration)) {
        throw "Invalid WSL configuration: $resolvedConfigurationPath"
    }

    return Get-WslHostState `
        -CommandAvailable $true `
        -VersionExitCode $versionExitCode `
        -VersionText $versionText `
        -StatusExitCode $statusExitCode `
        -InstallHelp $helpText `
        -MinimumVersion ([version] $configuration.MinimumWsl) `
        -VirtualMachinePlatformEnabled $virtualMachinePlatformEnabled `
        -RestartPending $restartPending
}

function Invoke-ElevatedHostAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update')]
        [string] $Action
    )

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $argumentList = Get-ElevatedBootstrapArguments -ScriptPath $PSCommandPath -HostAction $Action
    Write-Host "Administrator approval is required to $($Action.ToLowerInvariant()) WSL." -ForegroundColor Cyan
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    return $process.ExitCode
}

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'wsl-tools supports AMD64/X64 Windows hosts only.'
}

$windowsBuildText = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$windowsBuild = 0
if (-not [int]::TryParse([string] $windowsBuildText, [ref] $windowsBuild) -or $windowsBuild -lt 19041) {
    throw "Windows 10 build 19041 or newer is required; found build '$windowsBuildText'."
}

if ($HostAction) {
    if (-not (Test-IsAdministrator)) {
        throw 'The internal WSL host action must run as administrator.'
    }
    $arguments = Get-WslHostActionArguments -Action $HostAction
    & wsl.exe @arguments
    if ($LASTEXITCODE -notin @(0, 3010)) {
        throw "wsl.exe host action failed with exit code $LASTEXITCODE."
    }
    exit $LASTEXITCODE
}

$hostState = Get-CurrentWslHostState
$bootstrapAction = Get-WslBootstrapAction -HostState $hostState -VerifyOnly:$VerifyOnly
if ($bootstrapAction -eq 'ReadOnlyFailure') {
    throw "The WSL host is not ready ($hostState). VerifyOnly never installs or updates WSL."
}
if ($bootstrapAction -eq 'Restart') {
    Write-Host ''
    Write-Host 'Windows must restart before WSL can create a distribution.' -ForegroundColor Yellow
    Write-Host 'Restart Windows, then rerun this exact command to continue.' -ForegroundColor Yellow
    exit 3010
}
if ($bootstrapAction -in @('Install', 'Update')) {
    $action = $bootstrapAction
    if (-not $NonInteractive) {
        Write-Host ''
        Write-Host 'Windows host preparation:' -ForegroundColor Cyan
        Write-Host "  Action : $action WSL"
        Write-Host '  Scope  : WSL host components only; no Linux distribution will be installed yet'
        $confirmation = Read-Host 'Continue? [y/N]'
        if ($confirmation -notmatch '^(y|yes)$') {
            Write-Host 'Cancelled. No changes were made.'
            exit 0
        }
    }

    $hostExitCode = Invoke-ElevatedHostAction -Action $action
    if ($hostExitCode -notin @(0, 3010)) {
        throw "Elevated WSL host preparation failed with exit code $hostExitCode."
    }

    $hostState = Get-CurrentWslHostState
    if ($hostExitCode -eq 3010 -or $hostState -ne 'Ready') {
        Write-Host ''
        Write-Host 'Restart Windows, then rerun this exact command to continue.' -ForegroundColor Yellow
        exit 3010
    }
}

$setupParameters = @{}
foreach ($parameterName in @(
    'DistributionName', 'UbuntuRelease', 'UserName', 'UserId', 'Hostname', 'VhdSize', 'ConfigPath',
    'ImagePath', 'CacheDirectory', 'NonInteractive', 'Resume', 'VerifyOnly'
)) {
    if ($PSBoundParameters.ContainsKey($parameterName)) {
        $setupParameters[$parameterName] = $PSBoundParameters[$parameterName]
    }
}

& $setupPath @setupParameters
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
