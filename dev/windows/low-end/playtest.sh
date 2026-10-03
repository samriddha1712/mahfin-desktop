#!/bin/bash
# Launch under a profile, press Play on the hero, and capture the window twice.
#   ./playtest.sh <machine> <tag> [extra app args]
# Writes out/<machine>-<tag>-15s.png and -30s.png and prints what the page says.
cd "$(dirname "$0")"
machine=$1; tag=$2; extra=${3:-}
f="out/$machine-$tag.csv"; rm -f "$f" stop
powershell -NoProfile -File run.ps1 -Machine "$machine" -Duration 300 -Tag "$tag" -ExtraArgs "--reset-graphics $extra" >/dev/null 2>&1 &
until [ -f "$f" ] && [ "$(grep -c . "$f")" -ge 16 ]; do sleep 1; grep -q exited "$f" 2>/dev/null && { echo EXITED; exit 1; }; done
until node cdp.mjs eval "document.querySelectorAll('a[href^=\"/play/\"]').length" 2>/dev/null | grep -qv '^0$'; do sleep 1; done
node cdp.mjs eval "(()=>{const a=document.querySelector('a[href^=\"/play/\"]'); a.click(); return a.getAttribute('href')})()"
t0=$(tail -1 "$f" | cut -d, -f1)
until node cdp.mjs eval "location.pathname" 2>/dev/null | grep -q play; do sleep 1; done
sleep 15; powershell -NoProfile -File winshot.ps1 -Out "out/$machine-$tag-15s.png" >/dev/null
sleep 15; powershell -NoProfile -File winshot.ps1 -Out "out/$machine-$tag-30s.png" >/dev/null
node cdp.mjs eval "(()=>{const v=document.querySelector('.mahfin-mpv-surface'); return 'native=' + document.documentElement.classList.contains('mahfin-native-video') + ' introInDom=' + !!document.querySelector('[class*=\"z-30\"].inset-0') + ' time=' + ((document.body.innerText.match(/\\d+:\\d\\d \\/ [\\d:]+/)||[''])[0])})()"
log="$LOCALAPPDATA/Mahfin Desktop/profiles/a4bab4f497a2445682d089fd408403c2/logs/Mahfin Desktop.log"
grep -E "graphics tier|VO: \[" "$log" | sed 's/.* - //' | tail -2
awk -F, -v a="$t0" 'NR>1 && $1>a+20 {c+=$3; n++} END {if(n) printf "cpu during playback: %.0f%% of budget\n", c/n}' "$f"
[ -n "$KEEP" ] || { touch stop; while tasklist | grep -qi "Mahfin Desktop"; do sleep 1; done; rm -f stop; }
