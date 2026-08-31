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

configure_user_path() {
    local home_dir="$1"
    local owner_name="${2:-}"
    local marker='# wsl-tools: normalize PATH for login and non-login Bash shells.'
    local profile_end_marker='# wsl-tools: end login PATH normalization.'
    local final_marker='# wsl-tools: normalize PATH after interactive Bash customizations.'
    local final_end_marker='# wsl-tools: end interactive PATH normalization.'
    local helper_path="${home_dir}/.config/wsl-tools/path.sh"
    local bashrc_path="${home_dir}/.bashrc"
    local profile_path="${home_dir}/.profile"
    local temporary
    local -a owner_arguments=()
    # Expanded by the user's future shell, not by this provisioning process.
    # shellcheck disable=SC2016
    local -a hook=(
        "${marker}"
        'if [ -n "${BASH_VERSION:-}" ]; then'
        '    . "$HOME/.config/wsl-tools/path.sh"'
        'fi'
    )
    local -a profile_hook=(
        "${hook[@]}"
        "${profile_end_marker}"
    )
    # Expanded by the user's future shell, not by this provisioning process.
    # shellcheck disable=SC2016
    local -a final_hook=(
        "${final_marker}"
        'if [ -n "${BASH_VERSION:-}" ]; then'
        '    . "$HOME/.config/wsl-tools/path.sh"'
        'fi'
        "${final_end_marker}"
    )

    if [[ -n ${owner_name} ]]; then
        owner_arguments=(--owner="${owner_name}" --group="${owner_name}")
    fi
    if [[ ! -d ${home_dir}/.config ]]; then
        install -d -m 0755 "${owner_arguments[@]}" "${home_dir}/.config"
    fi
    install -d -m 0755 "${owner_arguments[@]}" \
        "${home_dir}/bin" \
        "${home_dir}/.local/bin" \
        "${home_dir}/.config/wsl-tools"

    temporary="$(mktemp)"
    cat > "${temporary}" <<'EOF'
# Managed by wsl-tools. Keep the first occurrence of every non-empty PATH entry.
case ":${PATH-}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac
case ":${PATH-}:" in
    *":${HOME}/bin:"*) ;;
    *) PATH="${HOME}/bin${PATH:+:${PATH}}" ;;
esac

_wsl_tools_deduplicate_path() {
    local entry
    local normalized=''
    local -a entries=()
    local -A seen=()

    IFS=: read -r -a entries <<< "${PATH-}"
    for entry in "${entries[@]}"; do
        [[ -n ${entry} ]] || continue
        [[ ${seen["${entry}"]+present} ]] && continue
        seen["${entry}"]=1
        normalized="${normalized:+${normalized}:}${entry}"
    done
    PATH="${normalized}"
    export PATH
}

_wsl_tools_deduplicate_path
unset -f _wsl_tools_deduplicate_path
EOF
    install -m 0644 "${owner_arguments[@]}" "${temporary}" "${helper_path}"
    rm -f "${temporary}"

    if [[ ! -e ${bashrc_path} ]]; then
        install -m 0644 "${owner_arguments[@]}" /dev/null "${bashrc_path}"
    fi
    if ! grep -Fqx -- "${marker}" "${bashrc_path}"; then
        temporary="$(mktemp)"
        printf '%s\n' "${hook[@]}" > "${temporary}"
        [[ -s ${bashrc_path} ]] && printf '\n' >> "${temporary}"
        cat "${bashrc_path}" >> "${temporary}"
        cat "${temporary}" > "${bashrc_path}"
        rm -f "${temporary}"
    fi

    # Reconcile this block to the end on every run so PATH changes added by a
    # user or installer after initial provisioning are normalized as well.
    temporary="$(mktemp)"
    if ! awk -v start="${final_marker}" -v finish="${final_end_marker}" '
        $0 == start { inside = 1; next }
        inside && $0 == finish { inside = 0; next }
        !inside { print }
        END { if (inside) exit 1 }
    ' "${bashrc_path}" > "${temporary}"; then
        rm -f "${temporary}"
        return 1
    fi
    cat "${temporary}" > "${bashrc_path}"
    rm -f "${temporary}"
    printf '%s\n' "${final_hook[@]}" >> "${bashrc_path}"

    if [[ ! -e ${profile_path} ]]; then
        install -m 0644 "${owner_arguments[@]}" /dev/null "${profile_path}"
    fi

    # Reconcile the login-shell block as well. Older installations do not have
    # an end marker, so remove only the exact legacy block and fail closed if a
    # managed block was edited instead of consuming nearby user configuration.
    temporary="$(mktemp)"
    if ! awk \
        -v start="${marker}" \
        -v condition='if [ -n "${BASH_VERSION:-}" ]; then' \
        -v source_line='    . "$HOME/.config/wsl-tools/path.sh"' \
        -v finish="${profile_end_marker}" '
        !inside && $0 == start {
            inside = 1
            phase = 1
            next
        }
        inside && phase == 1 {
            if ($0 != condition) exit 1
            phase = 2
            next
        }
        inside && phase == 2 {
            if ($0 != source_line) exit 1
            phase = 3
            next
        }
        inside && phase == 3 {
            if ($0 != "fi") exit 1
            phase = 4
            next
        }
        inside && phase == 4 {
            inside = 0
            phase = 0
            if ($0 == finish) next
            if ($0 == start) {
                inside = 1
                phase = 1
                next
            }
            print
            next
        }
        $0 == finish { exit 1 }
        { print }
        END {
            if (inside && phase < 4) exit 1
        }
    ' "${profile_path}" > "${temporary}"; then
        rm -f "${temporary}"
        return 1
    fi
    cat "${temporary}" > "${profile_path}"
    rm -f "${temporary}"
    if [[ -s ${profile_path} ]] && ! tail -n 1 "${profile_path}" | grep -Eq '^[[:space:]]*$'; then
        printf '\n' >> "${profile_path}"
    fi
    printf '%s\n' "${profile_hook[@]}" >> "${profile_path}"
}

# Exposed so the rewrite can be executed directly by tests.
if [[ ${1:-} == --write-distribution-conf ]]; then
    write_distribution_conf \
        "${2:?usage: provision.sh --write-distribution-conf PATH UID}" \
        "${3:?usage: provision.sh --write-distribution-conf PATH UID}"
    exit 0
fi
if [[ ${1:-} == --configure-user-path ]]; then
    configure_user_path "${2:?usage: provision.sh --configure-user-path HOME}"
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
configure_user_path "/home/${user_name}" "${user_name}"
install -d -o "${user_name}" -g "${user_name}" -m 0755 "/home/${user_name}/projects"
printf 'Baseline provisioning complete.\n'
