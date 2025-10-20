_lfsctl_completion() {
  local cur prev cmds
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  cmds="bootstrap bs build b install i uninstall u update up deps d pipeline info logs help"
  COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
  return 0
}
complete -F _lfsctl_completion lfsctl
