# shellcheck shell=bash
[[ $- == *i* ]] || return

[[ -f /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion

HISTSIZE=10000
HISTCONTROL=ignoredups
PS1='\[\e[1;33m\][netdebug ${HOSTNAME}]\[\e[0m\] \w \$ '
export EDITOR=vim

alias ll='ls -alF --color=auto'
alias tools='cat /etc/motd'
alias k=kubectl
complete -o default -F __start_kubectl k 2>/dev/null

cat /etc/motd
