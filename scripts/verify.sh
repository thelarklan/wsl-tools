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
oobe_section() { bash "${repo_root}/scripts/oobe-section.sh" /etc/wsl-distribution.conf; }
oobe_disabled() { ! oobe_section | grep -Eq '^[[:space:]]*command[[:space:]]*='; }
default_uid_matches() { oobe_section | grep -Eq "^[[:space:]]*defaultUid[[:space:]]*=[[:space:]]*$(id -u)[[:space:]]*$"; }
all_packages_installed() {
    local packages=()
    mapfile -t packages < <(sed 's/#.*$//; /^[[:space:]]*$/d' "${repo_root}/packages.txt")
    dpkg-query -W "${packages[@]}" >/dev/null
}

check 'Ubuntu distribution' grep -qx ID=ubuntu /etc/os-release
check 'Supported Ubuntu LTS release' grep -Eq '^VERSION_ID="?(24\.04|26\.04)"?$' /etc/os-release
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
