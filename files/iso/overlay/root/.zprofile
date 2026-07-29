# Autostart the installer on the live ISO.
#
# Only on tty1: Alt+F2 then stays a plain root shell, which is the debugging
# path when the installer itself is what's broken.
#
# Invoked as `bash installer.sh` rather than executed directly. archiso's
# file_permissions array in profiledef.sh is the only thing that can grant the
# exec bit inside the ISO, and forgetting to update it there is a silent
# failure at boot; calling the interpreter sidesteps the whole question.

if [[ $(tty) == /dev/tty1 ]]; then
  bash /root/installer.sh
  status=$?
  if [ "$status" -ne 0 ]; then
    # printf rather than zsh's `print -P`: this file is short enough to keep
    # shell-agnostic, and a syntax error here is a black screen at boot.
    printf '\n\033[1;31minstaller exited with status %s\033[0m\n' "$status"
    printf 'rerun:  \033[1mbash /root/installer.sh\033[0m\n'
    printf 'log:    /tmp/manuserver-install.log\n\n'
  fi
fi
