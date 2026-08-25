#!/usr/bin/env bash
set -Eeuo pipefail

# WSL runs the stock image's OOBE wizard on the first launch that starts an
# interactive shell, and stamps `[oobe] defaultUid` into the distribution's
# registry entry. That registry value outranks `[user] default` in
# /etc/wsl.conf, so a stock `defaultUid=1000` drops the user into a root shell
# whenever provisioning allocated any other UID. Rewrite the file so the
# wizard never runs and the recorded UID is the one we actually created.
write_distribution_conf() {
    local path="$1"
    local uid="$2"

    if [[ ! ${uid} =~ ^[0-9]+$ ]]; then
        echo "invalid default UID: ${uid}" >&2
        return 1
    fi

    local line trimmed key
    local -a output=()
    local in_oobe=0 wrote_uid=0

    if [[ -f ${path} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [[ ${trimmed} =~ ^\[[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*\] ]]; then
                if ((in_oobe)) && ((!wrote_uid)); then
                    output+=("defaultUid=${uid}")
                    wrote_uid=1
                fi
                in_oobe=0
                [[ ${BASH_REMATCH[1]} == oobe ]] && in_oobe=1
                output+=("${line}")
                continue
            fi
            if ((in_oobe)); then
                key="${trimmed%%=*}"
                key="${key%"${key##*[![:space:]]}"}"
                case "${key}" in
                    command)
                        continue
                        ;;
                    defaultUid)
                        output+=("defaultUid=${uid}")
                        wrote_uid=1
                        continue
                        ;;
                esac
            fi
            output+=("${line}")
        done < "${path}"
        if ((in_oobe)) && ((!wrote_uid)); then
            output+=("defaultUid=${uid}")
            wrote_uid=1
        fi
    fi

    if ((!wrote_uid)); then
        ((${#output[@]})) && output+=('')
        output+=('[oobe]' "defaultUid=${uid}")
    fi

    printf '%s\n' "${output[@]}" > "${path}"
}

# Exposed so the rewrite can be executed directly by tests.
if [[ ${1:-} == --write-distribution-conf ]]; then
    write_distribution_conf \
        "${2:?usage: provision.sh --write-distribution-conf PATH UID}" \
        "${3:?usage: provision.sh --write-distribution-conf PATH UID}"
    exit 0
fi

user_name="${1:?usage: provision.sh USER HOSTNAME USER_ID [PACKAGE ...]}"
host_name="${2:?usage: provision.sh USER HOSTNAME USER_ID [PACKAGE ...]}"
user_id="${3:?usage: provision.sh USER HOSTNAME USER_ID [PACKAGE ...]}"
shift 3
packages=("$@")

for package in "${packages[@]}"; do
    if [[ ! ${package} =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]]; then
        echo "invalid package name: ${package}" >&2
        exit 1
    fi
done

if [[ ${EUID} -ne 0 ]]; then
    echo 'provision.sh must run as root' >&2
    exit 1
fi

if [[ ! ${user_name} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "invalid Linux username: ${user_name}" >&2
    exit 1
fi
if [[ ! ${host_name} =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
    echo "invalid hostname: ${host_name}" >&2
    exit 1
fi
if [[ ! ${user_id} =~ ^[0-9]+$ ]] || ((user_id < 1000 || user_id > 60000)); then
    echo "invalid Linux user ID: ${user_id}" >&2
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo 'the Ubuntu image must provide sudo' >&2
    exit 1
fi

if ! id "${user_name}" >/dev/null 2>&1; then
    useradd --uid "${user_id}" --create-home --groups sudo --shell /bin/bash "${user_name}"
fi
actual_user_id="$(id -u "${user_name}")"
if [[ ${actual_user_id} != "${user_id}" ]]; then
    echo "existing user ${user_name} has UID ${actual_user_id}; refusing automatic UID migration" >&2
    exit 1
fi
usermod --append --groups sudo "${user_name}"
passwd --lock "${user_name}" >/dev/null

# WSL starts the default user's systemd session with `login -f`. Lingering can
# race that WSL-managed session (especially with WSLg), so keep it disabled.
loginctl disable-linger "${user_name}" >/dev/null 2>&1 || true

install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${user_name}" > /etc/sudoers.d/90-wsl-dev-user
chmod 0440 /etc/sudoers.d/90-wsl-dev-user
visudo --check --file=/etc/sudoers.d/90-wsl-dev-user >/dev/null

cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[automount]
enabled=true
mountFsTab=true
options=metadata,umask=22,fmask=11

[network]
hostname=${host_name}
generateHosts=true
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=true

[user]
default=${user_name}

[gpu]
enabled=true

[time]
useWindowsTimezone=true
EOF

write_distribution_conf /etc/wsl-distribution.conf "${user_id}"

if ((${#packages[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install --yes --no-install-recommends "${packages[@]}"
    apt-get clean
fi
install -d -o "${user_name}" -g "${user_name}" -m 0755 "/home/${user_name}/projects"
printf 'Baseline provisioning complete.\n'
