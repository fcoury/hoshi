#!/usr/bin/env bash
# Fake request log for the prod-api session; fits a ~32-column phone screen.
G='\e[38;5;114m'; Y='\e[38;5;221m'; Rd='\e[38;5;203m'; D='\e[38;5;245m'; B='\e[38;5;75m'; R='\e[0m'
paths=(/v1/sessions /v1/sessions/42 /v1/hosts /healthz /v1/events /v1/hosts/7)
i=0
while true; do
  p=${paths[$((i % ${#paths[@]}))]}
  case $((i % 9)) in 4) c="${Y}304${R}";; 7) c="${Rd}429${R}";; *) c="${G}200${R}";; esac
  printf "${B}GET${R} %-16s %b ${D}%2dms${R}\n" "$p" "$c" $((3 + i * 7 % 40))
  i=$((i + 1)); sleep 0.8
done
