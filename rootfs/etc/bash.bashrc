# shellcheck shell=bash
# System-wide interactive bash config. Lives here rather than in ~/.bashrc so
# it also applies when the pod runs as an arbitrary non-root UID.
[[ $- == *i* ]] || return

shopt -s checkwinsize

# Non-root UIDs without a passwd entry get HOME=/, which isn't writable;
# give them a scratch home so history, rclone/psql/neomutt config etc. work.
if [[ ! -w ${HOME:-/} ]]; then
  export HOME=/tmp/home-$(id -u)
  mkdir -p "$HOME"
fi

[[ -f /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion

HISTSIZE=10000
HISTCONTROL=ignoredups
PS1='\[\e[1;33m\][netdebug${NETDEBUG_VARIANT:+-$NETDEBUG_VARIANT} \u@\h]\[\e[0m\] \w \$ '
export EDITOR=vim

alias ll='ls -alF --color=auto'
alias tools='cat /etc/motd'
alias k=kubectl
complete -o default -F __start_kubectl k 2>/dev/null

cat /etc/motd
