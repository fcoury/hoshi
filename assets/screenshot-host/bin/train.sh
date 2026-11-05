#!/usr/bin/env bash
# Fake but plausible training log for the gpu-box session thumbnail.
G='\e[38;5;114m'; B='\e[38;5;75m'; Y='\e[38;5;221m'; D='\e[38;5;245m'; R='\e[0m'
printf "${B}train.py${R} ${D}--config configs/small.yaml --epochs 12${R}\n\n"
loss=2.41
for epoch in $(seq 1 12); do
  for step in 100 200 300 400; do
    loss=$(python3 -c "print(f'{$loss*0.968:.3f}')")
    printf "${D}epoch${R} %2d ${D}step${R} %4d  ${Y}loss${R} %s  ${D}lr${R} 3.0e-4  ${G}%3d it/s${R}\n" "$epoch" "$step" "$loss" $((180 + RANDOM % 20))
    sleep 0.6
  done
  printf "${G}✔ epoch %d${R} ${D}val_loss${R} %s\n" "$epoch" "$loss"
done
tail -f /dev/null
