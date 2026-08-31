Set-StrictMode -Version Latest

function Test-WslDistributionName {
    param([AllowEmptyString()][string] $Value)
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
}

function Test-LinuxUserName {
    param([AllowEmptyString()][string] $Value)
    return $Value -cmatch '^[a-z_][a-z0-9_-]{0,31}\z'
}

function Test-WslUserId {
    param([AllowNull()] $Value)

    $parsed = 0
    return [int]::TryParse([string] $Value, [ref] $parsed) -and
        $parsed -ge 1000 -and $parsed -le 60000
}

function Get-NextAvailableWslUserId {
    param(
        [int[]] $UsedUserIds = @(),
        [AllowNull()] $RequestedUserId
    )

    $used = @{}
    foreach ($userId in $UsedUserIds) {
        if (Test-WslUserId $userId) { $used[[int] $userId] = $true }
    }

    if ($null -ne $RequestedUserId) {
        if (-not (Test-WslUserId $RequestedUserId)) { throw 'The Linux user ID must be between 1000 and 60000.' }
        $requested = [int] $RequestedUserId
        if ($used.ContainsKey($requested)) { throw "Linux user ID $requested is already used by another WSL distribution." }
        return $requested
    }

    for ($candidate = 1000; $candidate -le 60000; $candidate++) {
        if (-not $used.ContainsKey($candidate)) { return $candidate }
    }
    throw 'No unused Linux user ID is available between 1000 and 60000.'
}

function Resolve-WslUserId {
    param([AllowNull()] $CurrentUserId, [int[]] $UsedUserIds = @(), [AllowNull()] $RequestedUserId)

    if ($null -ne $CurrentUserId) {
        if (-not (Test-WslUserId $CurrentUserId)) { throw 'The existing Linux user ID must be between 1000 and 60000.' }
        $current = [int] $CurrentUserId
        if ($null -ne $RequestedUserId) {
            if (-not (Test-WslUserId $RequestedUserId)) { throw 'The Linux user ID must be between 1000 and 60000.' }
            if ([int] $RequestedUserId -ne $current) {
                throw "The Linux user already has UID $current; refusing to migrate it automatically to UID $RequestedUserId."
            }
        }
        return $current
    }
    return Get-NextAvailableWslUserId -UsedUserIds $UsedUserIds -RequestedUserId $RequestedUserId
}

function Test-WslHostName {
    param([AllowEmptyString()][string] $Value)
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}\z'
}

function Test-WslVhdSize {
    param([AllowEmptyString()][string] $Value)
    return $Value -match '^\d+(B|M|MB|G|GB|T|TB)\z'
}

function ConvertFrom-WslVersionText {
    param([AllowEmptyString()][string] $Value)

    if ($Value -notmatch '^[^\r\n]*?(\d+)\.(\d+)\.(\d+)') {
        return $null
    }

    return [version]::new([int] $Matches[1], [int] $Matches[2], [int] $Matches[3])
}

function Test-WslConfiguration {
    param([Parameter(Mandatory)][hashtable] $Configuration)

    $requiredKeys = @('DistributionName', 'DefaultUser', 'Hostname', 'VhdSize', 'MinimumWsl', 'Images')
    foreach ($key in $requiredKeys) {
        if (-not $Configuration.ContainsKey($key)) { return $false }
    }

    if (-not (Test-WslDistributionName $Configuration.DistributionName)) { return $false }
    if (-not (Test-LinuxUserName $Configuration.DefaultUser)) { return $false }
    if (-not (Test-WslHostName $Configuration.Hostname)) { return $false }
    if (-not (Test-WslVhdSize $Configuration.VhdSize)) { return $false }

    $minimumVersion = $null
    if (-not [version]::TryParse([string] $Configuration.MinimumWsl, [ref] $minimumVersion)) { return $false }

    if (-not $Configuration.Images.ContainsKey('AMD64')) { return $false }
    $image = $Configuration.Images.AMD64
    if (-not $image) { return $false }
    foreach ($key in @('FileName', 'Url', 'Sha256')) {
        if (-not $image.ContainsKey($key)) { return $false }
    }
    if ($image.FileName -notmatch '^ubuntu-[0-9.]+-wsl-amd64\.wsl\z') { return $false }
    if ($image.Sha256 -notmatch '^[a-f0-9]{64}\z') { return $false }

    $imageUri = $null
    if (-not [uri]::TryCreate([string] $image.Url, [UriKind]::Absolute, [ref] $imageUri)) { return $false }
    if ($imageUri.Scheme -ne 'https') { return $false }

    return $true
}

function Get-WslInstallArguments {
    param(
        [Parameter(Mandatory)][string] $ImagePath,
        [Parameter(Mandatory)][string] $DistributionName,
        [Parameter(Mandatory)][string] $VhdSize
    )

    return @(
        '--install', '--from-file', $ImagePath,
        '--name', $DistributionName,
        '--vhd-size', $VhdSize,
        '--no-launch'
    )
}

function Test-WslInstallHelp {
    param([AllowEmptyString()][string] $Value)

    foreach ($option in @('--from-file', '--name', '--no-launch', '--vhd-size')) {
        if (-not $Value.Contains($option)) { return $false }
    }
    return $true
}

function Read-WslPackageList {
    param([Parameter(Mandatory)][string] $Path)

    $packages = @(Get-Content -LiteralPath $Path |
        ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
        Where-Object { $_ })
    if (-not $packages.Count) { throw "$Path contains no packages." }
    foreach ($package in $packages) {
        if ($package -notmatch '^[A-Za-z0-9][A-Za-z0-9._+:-]*\z') {
            throw "Invalid package name '$package'."
        }
    }
    return $packages
}

function ConvertTo-WslByteSize {
    param([Parameter(Mandatory)][string] $Value)

    if (-not (Test-WslVhdSize $Value)) { throw "Invalid WSL size '$Value'." }
    $Value -match '^(\d+)(B|M|MB|G|GB|T|TB)\z' | Out-Null
    $sizeValue = [uint64] $Matches[1]
    $multiplier = switch ($Matches[2]) {
        'B' { [uint64] 1 }
        { $_ -in 'M', 'MB' } { [uint64] 1MB }
        { $_ -in 'G', 'GB' } { [uint64] 1GB }
        { $_ -in 'T', 'TB' } { [uint64] 1TB }
    }
    return $sizeValue * $multiplier
}

function ConvertTo-BashLineEndings {
    param([AllowEmptyString()][string] $Value)

    return $Value -replace "`r`n", "`n" -replace "`r", "`n"
}

function Get-WslHostState {
    param(
        [Parameter(Mandatory)][bool] $CommandAvailable,
        [Parameter(Mandatory)][int] $VersionExitCode,
        [AllowEmptyString()][string] $VersionText,
        [Parameter(Mandatory)][int] $StatusExitCode,
        [AllowEmptyString()][string] $InstallHelp,
        [Parameter(Mandatory)][version] $MinimumVersion,
        [Parameter(Mandatory)][bool] $VirtualMachinePlatformEnabled,
        [Parameter(Mandatory)][bool] $RestartPending
    )

    if (-not $CommandAvailable -or $VersionExitCode -ne 0) {
        return 'Absent'
    }
    if (-not $VirtualMachinePlatformEnabled) {
        return 'Absent'
    }
    if ($RestartPending) {
        return 'RestartRequired'
    }

    $version = ConvertFrom-WslVersionText $VersionText
    if (-not $version -or $version -lt $MinimumVersion) {
        return 'UpdateRequired'
    }
    if (-not (Test-WslInstallHelp $InstallHelp)) {
        return 'UpdateRequired'
    }
    if ($StatusExitCode -ne 0) {
        return 'Absent'
    }

    return 'Ready'
}

function Get-WslHostActionArguments {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update')]
        [string] $Action
    )

    if ($Action -eq 'Install') {
        return @('--install', '--no-distribution')
    }
    return @('--update')
}

function Get-WslBootstrapAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Ready', 'Absent', 'UpdateRequired', 'RestartRequired')]
        [string] $HostState,
        [switch] $VerifyOnly
    )

    if ($HostState -eq 'Ready') {
        return 'Provision'
    }
    if ($VerifyOnly) {
        return 'ReadOnlyFailure'
    }
    if ($HostState -eq 'RestartRequired') {
        return 'Restart'
    }
    if ($HostState -eq 'Absent') {
        return 'Install'
    }
    return 'Update'
}

function Get-ElevatedBootstrapArguments {
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update')]
        [string] $HostAction
    )

    $escapedPath = $ScriptPath.Replace("'", "''")
    $command = "& '$escapedPath' -HostAction '$HostAction'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
}

# Returns the recorded UID, or $null only after positively locating the
# distribution and finding no DefaultUid value on it. Every other outcome throws,
# so a registry that could not be read is never mistaken for one that was read
# and found empty.
function Resolve-WslRegisteredUserId {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]] $RegistryEntries,
        [Parameter(Mandatory)][string] $DistributionName
    )

    foreach ($entry in $RegistryEntries) {
        if ($null -eq $entry) { continue }
        $entryProperties = $entry.PSObject.Properties
        if (-not $entryProperties['DistributionName']) { continue }
        if ($entry.DistributionName -ne $DistributionName) { continue }
        if (-not $entryProperties['DefaultUid']) { return $null }

        $parsed = 0
        if (-not [int]::TryParse([string] $entry.DefaultUid, [ref] $parsed)) {
            throw "Distribution '$DistributionName' has a non-numeric registry DefaultUid: '$($entry.DefaultUid)'."
        }
        return $parsed
    }
    throw "Distribution '$DistributionName' was not found under the WSL registry key."
}

function Get-WslRegisteredUserId {
    param([Parameter(Mandatory)][string] $DistributionName)

    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $lxssPath)) {
        throw "The WSL registry key '$lxssPath' does not exist."
    }
    $entries = foreach ($key in @(Get-ChildItem -LiteralPath $lxssPath -ErrorAction Stop)) {
        Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
    }
    return Resolve-WslRegisteredUserId -RegistryEntries @($entries) -DistributionName $DistributionName
}

function Get-WslDefaultUidState {
    param(
        [AllowNull()] $RegisteredUserId,
        [Parameter(Mandatory)][int] $ExpectedUserId
    )

    # WSL records 0 when no default user has been stamped for the distribution,
    # which it also does for a freshly registered distribution whose OOBE has not
    # run. Observed on a provisioned distribution: registry DefaultUid was 0 while
    # a bare `wsl -d <name>` launch still resolved the user from /etc/wsl.conf.
    # Only a nonzero disagreement is the failure #17 describes.
    if ($null -eq $RegisteredUserId -or [string] $RegisteredUserId -eq '' -or [int] $RegisteredUserId -eq 0) { return 'Unset' }
    if ([int] $RegisteredUserId -eq $ExpectedUserId) { return 'Match' }
    return 'Mismatch'
}

function Get-WslExistingDistributionMessage {
    param(
        [Parameter(Mandatory)][string] $DistributionName,
        [Parameter(Mandatory)][string] $UserName,
        [Parameter(Mandatory)][string] $Hostname,
        [Parameter(Mandatory)][string] $VhdSize
    )

    $resumeCommand = ".\Start-WslTools.cmd -DistributionName '$DistributionName' " +
        "-UserName '$UserName' -Hostname '$Hostname' -VhdSize '$VhdSize' " +
        '-Resume -NonInteractive'
    return "Distribution '$DistributionName' already exists; refusing to overwrite it. " +
        "If a previous run failed during provisioning, resume it with: $resumeCommand"
}

Export-ModuleMember -Function @(
    'Test-WslDistributionName',
    'Test-LinuxUserName',
    'Test-WslUserId',
    'Get-NextAvailableWslUserId',
    'Resolve-WslUserId',
    'Test-WslHostName',
    'Test-WslVhdSize',
    'ConvertFrom-WslVersionText',
    'Test-WslConfiguration',
    'Get-WslInstallArguments',
    'Test-WslInstallHelp',
    'Read-WslPackageList',
    'ConvertTo-WslByteSize',
    'ConvertTo-BashLineEndings',
    'Get-WslHostState',
    'Get-WslHostActionArguments',
    'Get-WslBootstrapAction',
    'Get-ElevatedBootstrapArguments',
    'Resolve-WslRegisteredUserId',
    'Get-WslRegisteredUserId',
    'Get-WslDefaultUidState',
    'Get-WslExistingDistributionMessage'
)
