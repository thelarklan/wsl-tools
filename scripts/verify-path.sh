#!/usr/bin/env bash
set -Eeuo pipefail

# This command is expanded inside each child shell.
# shellcheck disable=SC2016
path_entry_once_command='target="$1"; count=0; IFS=: read -r -a entries <<< "${PATH-}"; for entry in "${entries[@]}"; do [[ ${entry} == "${target}" ]] && ((count += 1)); done; ((count == 1))'

check_shell_mode() {
    local options="$1"
    local prelude="$2"
    local target="$3"

    HOME="${HOME}" bash "${options}" "${prelude}${path_entry_once_command}" _ "${target}" >/dev/null 2>&1
}

for target in "${HOME}/bin" "${HOME}/.local/bin"; do
    check_shell_mode -ic '' "${target}"
    check_shell_mode -lc '' "${target}"
    check_shell_mode -lic '' "${target}"
    # HOME is expanded inside the child interactive shell.
    # shellcheck disable=SC2016
    check_shell_mode -ic '. "$HOME/.bashrc"; . "$HOME/.bashrc"; ' "${target}"
done

# Exercise the managed helper directly with inherited duplicates and an empty
# element. The result must retain every distinct directory while dropping the
# empty entry and later duplicates.
polluted_path="${HOME}/.local/bin:${HOME}/.local/bin:/usr/local/bin::/usr/bin:${HOME}/bin:${HOME}/bin"
PATH="${polluted_path}" HOME="${HOME}" bash --noprofile --norc -c '
    . "$HOME/.config/wsl-tools/path.sh"
    [[ :$PATH: == *":$HOME/bin:"* ]]
    [[ :$PATH: == *":$HOME/.local/bin:"* ]]
    [[ :$PATH: == *":/usr/local/bin:"* ]]
    [[ :$PATH: == *":/usr/bin:"* ]]
    [[ $PATH != :* && $PATH != *: && $PATH != *::* ]]
    IFS=: read -r -a entries <<< "$PATH"
    declare -A seen=()
    for entry in "${entries[@]}"; do
        [[ ! ${seen["${entry}"]+present} ]]
        seen["${entry}"]=1
    done
' >/dev/null
