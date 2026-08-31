# wsl-tools

Build consistent AMD64 Ubuntu development environments with WSL.

## Quick start

No Windows Git installation, GitHub login, or PowerShell 7 installation is
required. On an AMD64 Windows 10/11 machine:

1. Open the [latest release](https://github.com/thelarklan/wsl-tools/releases/latest).
2. Download `wsl-tools-<version>-windows.zip` and extract it to a local folder.
3. Open Windows PowerShell in the extracted folder.
4. Run the environments you want:

```powershell
.\Start-WslTools.cmd -DistributionName codex -UserName thelarkbot -Hostname codex -VhdSize 50GB -NonInteractive
.\Start-WslTools.cmd -DistributionName claude -UserName thelarklan -Hostname claude -VhdSize 50GB -NonInteractive
```

If setup asks for a restart, restart Windows and rerun the identical command.
Then launch either environment:

```powershell
wsl.exe --distribution codex --cd ~
wsl.exe --distribution claude --cd ~
```

That is the complete normal setup. The sections below explain what the launcher
does, recovery options, verification, and project development.

## How bootstrap works

The launcher uses Windows PowerShell 5.1 and shows the effective plan before it
changes the host or creates a distribution. On a fresh Windows installation it
asks for administrator approval and runs `wsl --install --no-distribution`, so
WSL does not create an unwanted store distribution. If Windows needs a restart,
restart and rerun the identical command. The elevated process changes only the
WSL host; distribution registration runs as the original Windows user.

The optional `.sha256` file on the release page can be checked before extracting:

```powershell
Get-FileHash .\wsl-tools-<version>-windows.zip -Algorithm SHA256
Get-Content .\wsl-tools-<version>-windows.zip.sha256
```

## Codex and Claude environments

The first command may request administrator approval and a Windows restart. If
it does, rerun that first command after restarting, then run the second command.
Both environments use the verified Ubuntu image; the second setup reuses the
download cache.

For reliable simultaneous systemd user sessions, setup inspects regular-user
UIDs in existing WSL distributions and assigns the first unused UID. In this
example `codex` normally receives UID 1000 and `claude` receives UID 1001. Use
`-UserId` to request another value from 1000 through 60000; setup fails closed
if another inspected distribution already uses it.

The names are examples, not checked-in defaults. `wsl-tools` creates generic
Linux development environments; it does not install the Codex or Claude CLIs,
configure agent credentials, or change editor settings.

## Guided and automated setup

Run the launcher without flags for guided setup:

```powershell
.\Start-WslTools.cmd
```

The CLI lists the pinned Ubuntu WSL images first, then prompts for the image,
distribution name, Linux user, hostname, and VHD maximum. It selects a
host-wide unused Linux UID, then shows the plan. The root bootstrap accepts the
same public parameters as `scripts/setup.ps1`:

```powershell
.\Start-WslTools.cmd `
  -UbuntuRelease 24.04 `
  -DistributionName Work-Ubuntu `
  -UserName developer `
  -UserId 1001 `
  -Hostname work-ubuntu `
  -VhdSize 50GB `
  -NonInteractive
```

Explicit flags override `config.psd1`. `-UbuntuRelease` accepts `24.04` or
`26.04`; non-interactive runs default to `26.04`. Use `-ImagePath` for an
already downloaded Canonical image or `-CacheDirectory` to choose the download
cache. Every image must match the pinned SHA-256 for the selected release.

The setup command refuses to overwrite an existing distribution. If initial
provisioning was interrupted after the distribution was created, repeat the
effective settings and resume explicitly:

```powershell
.\Start-WslTools.cmd -UbuntuRelease 24.04 -DistributionName Work-Ubuntu -UserName developer `
  -Hostname work-ubuntu -VhdSize 50GB -Resume -NonInteractive
```

Resume preserves an existing user's UID. It never rewrites ownership or
automatically migrates an existing user to a different UID.

Verify an existing environment without reconciling packages or writing state:

```powershell
.\Start-WslTools.cmd -UbuntuRelease 24.04 -DistributionName Work-Ubuntu -UserName developer `
  -Hostname work-ubuntu -VhdSize 50GB -VerifyOnly -NonInteractive
```

## Requirements and configuration

- Windows 10 build 19041 or newer, or Windows 11
- AMD64/X64 host
- Permission to approve WSL installation or updates when required

`config.psd1` contains generic public defaults:

- distribution: `UbuntuDev-26.04`
- Linux user: `developer`
- hostname: `ubuntu-dev`
- maximum VHD size: `50GB`
- minimum Store WSL: `2.4.10`
- pinned Ubuntu 26.04 and Ubuntu 24.04.4 AMD64 WSL images and SHA-256 checksums

For a read-only check on an already prepared host:

```powershell
powershell.exe -NoProfile -File .\scripts\check-prerequisites.ps1
```

## Development packages

`packages.txt` is the baseline APT manifest. It includes Git and Git LFS,
GitHub CLI, Python, Podman, GCC/build tools, fzf, ripgrep, ShellCheck, tmux, and
common utilities. Package versions follow Ubuntu updates.

Add missing manifest packages to an existing configured distribution from
PowerShell:

```powershell
.\scripts\sync-packages.ps1 -DistributionName Work-Ubuntu -UbuntuRelease 24.04
```

Or run from the repository mounted inside the distribution:

```bash
bash scripts/sync-packages.sh
```

Removing a manifest entry never uninstalls software.

## Verification and state

Setup and package synchronization verify the OS, architecture, configured
identity, complete package manifest, rootless Podman, project directory, and
hostname, and filesystem maximum. An unavailable systemd user manager is reported as a
warning because Podman can fall back to `cgroupfs`; it does not make an
otherwise usable environment fail verification. State capture runs even if a
required verification check fails, writing an ignored inventory under `state/`
with exact package and selected tool versions for diagnosis.

Before a release, follow the
[clean-machine acceptance checklist](docs/clean-machine-acceptance.md).

Development checks:

```powershell
Install-Module Pester -Scope CurrentUser -Force -RequiredVersion 5.7.1
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
Invoke-Pester .\tests -CI
```

On Linux, also run:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
```

## Safety

Bootstrap validates Windows and WSL before provisioning, performs host changes
in a separate elevated process, and installs WSL without a default distribution.
Setup validates every value, verifies the Ubuntu image checksum, and rejects an
existing distribution unless `-Resume` or `-VerifyOnly` is explicit.

UID discovery is read-only across existing distributions. Explicit UID
collisions and attempts to change an existing user's UID fail closed.

Provisioning disables the stock image's first-launch OOBE wizard and records the
allocated UID in `/etc/wsl-distribution.conf`. Without that, the wizard runs on
the first launch that opens an interactive shell and stamps the image's
`defaultUid=1000` into the distribution's registry entry, which outranks
`[user] default` in `/etc/wsl.conf` and drops the user into a root shell whenever
provisioning allocated any other UID. Verification checks the recorded UID and
the registry value. If a distribution created before this fix already shows the
mismatch, repair it with:

```powershell
wsl --manage <distribution> --set-default-user <user>
```

The project never invokes `wsl --unregister` because that irreversibly deletes a
distribution. It also never invokes `wsl --set-default`; an existing default is
left alone. If the machine has never had a distribution, WSL may naturally make
the first created distribution the default.
