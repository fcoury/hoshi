# Screenshot host shell. Fixed, tidy prompt: fcoury@devbox ~/hoshi (master) ❯
[ -z "$PS1" ] && return

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=${TERM:-xterm-256color}
export EDITOR=vim PAGER=less LESS=-R
export PATH="$HOME/.local/bin:/opt/shots:$PATH"
HISTFILE=/dev/null

alias ls='ls --color=auto' ll='ls -lh --color=auto' bat='batcat --paging=never'

__shots_branch() {
  local b
  b=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  printf ' \001\e[38;5;141m\002(%s)\001\e[0m\002' "$b"
}

PS1='\[\e[38;5;114m\]\u@\h\[\e[0m\] \[\e[38;5;75m\]\w\[\e[0m\]$(__shots_branch) \[\e[38;5;215m\]❯\[\e[0m\] '
