# shellcheck shell=sh
# Datel OS at an SSH login: what the printer is doing (the motd scripts),
# then the prompt. Sourced by /etc/profile from /etc/profile.d.
if [ -n "${SSH_CONNECTION-}" ] && [ -z "${DATEL_MOTD_SHOWN-}" ] && [ -t 1 ]; then
    export DATEL_MOTD_SHOWN=1
    for m in /usr/lib/datel/motd/*; do [ -x "$m" ] && "$m"; done
fi
[ -r /usr/lib/datel/prompt.sh ] && . /usr/lib/datel/prompt.sh
