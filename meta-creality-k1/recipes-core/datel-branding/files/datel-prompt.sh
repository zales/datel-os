# shellcheck shell=sh
# Datel OS's shell prompt, sourced from /etc/profile.d/datel.sh after
# /etc/profile set the plain one. BusyBox ash expands PS1 at every prompt,
# so the arrow turns red after a command that failed.
#
#   ■ root@datel ~ #
#
# The mark's red square, the user (red for root, grey otherwise), the host
# in white, the directory in amber, and the arrow (❯, # for root).
[ "${DATEL_PROMPT-}" = 0 ] && return 0
_dp_red='\[\033[38;5;160m\]' _dp_grey='\[\033[38;5;243m\]' _dp_dim='\[\033[38;5;238m\]'
_dp_white='\[\033[1;38;5;255m\]' _dp_amber='\[\033[38;5;221m\]' _dp_bad='\[\033[38;5;203m\]' _dp_n='\[\033[0m\]'
if [ "$(id -u)" -eq 0 ]; then _dp_user=$_dp_red _dp_sign='#'; else _dp_user=$_dp_grey _dp_sign='❯'; fi
__datel_arrow() { if [ "$1" -eq 0 ]; then printf '%b' "$_dp_red"; else printf '%b' "$_dp_bad"; fi; }
PS1="$_dp_red■$_dp_n $_dp_user\\u$_dp_dim@$_dp_white\\h$_dp_n $_dp_amber\\w$_dp_n \$(__datel_arrow \$?)$_dp_sign$_dp_n "
case $TERM in xterm* | rxvt* | tmux* | screen* | alacritty | foot*) PS1="\\[\\033]0;\\u@\\h: \\w\\a\\]$PS1" ;; esac
export PS1
