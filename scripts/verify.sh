#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

check() {
    local label="$1"
    shift
    if "$@"; then printf '[PASS] %s\n' "${label}"
    else printf '[FAIL] %s\n' "${label}" >&2; return 1
    fi
}

warn_check() {
    local label="$1"
    shift
    if "$@"; then printf '[PASS] %s\n' "${label}"
    else printf '[WARN] %s is unavailable. Rootless Podman will fall back to cgroupfs.\n' "${label}" >&2
    fi
}

tool_exists() { command -v "$1" >/dev/null; }
rootless_podman_works() { podman info >/dev/null; }
oobe_disabled() { [[ ! -f /etc/wsl-distribution.conf ]] || ! grep -Eq '^[[:space:]]*command[[:space:]]*=' /etc/wsl-distribution.conf; }
default_uid_matches() { grep -Eq "^[[:space:]]*defaultUid[[:space:]]*=[[:space:]]*$(id -u)[[:space:]]*$" /etc/wsl-distribution.conf; }
all_packages_installed() {
    local packages=()
    mapfile -t packages < <(sed 's/#.*$//; /^[[:space:]]*$/d' "${repo_root}/packages.txt")
    dpkg-query -W "${packages[@]}" >/dev/null
}

check 'Ubuntu distribution' grep -qx ID=ubuntu /etc/os-release
check 'Ubuntu 26.04 release' grep -Fq 26.04 /etc/os-release
check 'AMD64 architecture' test "$(uname -m)" = x86_64
check 'WSL 2 kernel' grep -qi microsoft /proc/sys/kernel/osrelease
check 'systemd is PID 1' test "$(cat /proc/1/comm)" = systemd
warn_check 'systemd user manager works' systemctl --user is-active --quiet default.target
check 'Passwordless sudo' sudo -n true
check 'Baseline packages installed' all_packages_installed
for tool in git gh git-lfs gcc fzf python3 podman; do
    check "${tool} is installed" tool_exists "${tool}"
done
check 'Rootless Podman works' rootless_podman_works
check 'First-launch OOBE disabled' oobe_disabled
check 'Distribution default UID matches this user' default_uid_matches
check 'Projects directory exists' test -d "${HOME}/projects"
echo 'All Linux-side checks passed.'
