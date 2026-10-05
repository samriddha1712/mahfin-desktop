#!/bin/bash
# One short run that does what a person does: sit on the home page, scroll it, press Play.
# Records Qt's own timing for every frame it draws, so the GPU path can be compared.
#   ./frametest.sh <machine> <tag> [gpu: default|igpu|dgpu] [extra app args]
# Writes out/<machine>-<tag>.csv, out/<machine>-<tag>-play.png and out/<machine>-<tag>.frames.
cd "$(dirname "$0")"
machine=$1; tag=$2; gpu=${3:-default}; extra=${4:-}
name="$machine-$tag"; f="out/$name.csv"; rm -f "$f" stop
log="$LOCALAPPDATA/Mahfin Desktop/profiles/a4bab4f497a2445682d089fd408403c2/logs/Mahfin Desktop.log"
before=$(wc -l < "$log" 2>/dev/null || echo 0)
gpuArg=""; [ "$gpu" != default ] && gpuArg="-Gpu $gpu"
QT_LOGGING_RULES="qt.scenegraph.time.renderloop=true" \
  powershell -NoProfile -File run.ps1 -Machine "$machine" $gpuArg -Duration 150 -Tag "$tag" -ExtraArgs "--reset-graphics $extra" >/dev/null 2>&1 &
until [ -f "$f" ] && [ "$(grep -c . "$f")" -ge 16 ]; do sleep 1; grep -q exited "$f" 2>/dev/null && { echo EXITED; exit 1; }; done
until node cdp.mjs eval "document.querySelectorAll('a[href^=\"/play/\"]').length" 2>/dev/null | grep -qv '^0$'; do sleep 1; done
sleep 3
mark() { echo "$1 $(date +%H:%M:%S.%3N)" >> "out/$name.marks"; }
rm -f "out/$name.marks"
mark idle;   echo "idle:   $(node cdp.mjs perf 8 | tr -d '\n ' )"
mark scroll; echo "scroll: $(node cdp.mjs scroll)"
mark play
node cdp.mjs eval "(()=>{const a=document.querySelector('a[href^=\"/play/\"]'); a.click(); return a.getAttribute('href')})()" >/dev/null
until node cdp.mjs eval "location.pathname" 2>/dev/null | grep -q play; do sleep 1; done
sleep 25; powershell -NoProfile -File winshot.ps1 -Out "out/$name-play.png" >/dev/null
mark end
touch stop; while tasklist | grep -qi "Mahfin.exe"; do sleep 1; done; rm -f stop
tail -n +"$((before+1))" "$log" > "out/$name.log"
grep -E "graphics tier|OpenGL renderer|hwdec|Using hardware decoding|VO: \[|\[vo/libmpv\].*(rendering|interop)" "out/$name.log" | sed 's/.* - //' | sort -u | head -12
grep -E "Frame rendered|Frame prepared" "out/$name.log" > "out/$name.frames"
# Frame timing per phase, from the log timestamps and Qt's own render/swap split.
awk -v marks="out/$name.marks" '
  BEGIN { while ((getline l < marks) > 0) { split(l, p, " "); n++; ph[n]=p[1]; split(p[2], t, ":"); at[n]=t[1]*3600+t[2]*60+t[3] } }
  { split($2, t, ":"); s=t[1]*3600+t[2]*60+t[3]; cur=""; for (i=1;i<n;i++) if (s>=at[i] && s<at[i+1]) cur=ph[i]; if (cur=="") next
    if (match($0, /render=[0-9.]+/)) r=substr($0, RSTART+7, RLENGTH-7)+0; else r=0
    if (last[cur]) { g=(s-last[cur])*1000; gaps[cur]=gaps[cur] " " g; if (g>50) slow[cur]++ ; if (g>gmax[cur]) gmax[cur]=g }
    last[cur]=s; cnt[cur]++; rs[cur]+=r; if (r>rmax[cur]) rmax[cur]=r; if (!first[cur]) first[cur]=s; lastt[cur]=s }
  END { for (k in cnt) { d=lastt[k]-first[k]; printf "%-7s frames=%d fps=%.1f render_avg=%.1fms render_max=%.0fms gap_max=%.0fms gaps>50ms=%d\n", k, cnt[k], (d>0?cnt[k]/d:0), rs[k]/cnt[k], rmax[k], gmax[k], slow[k] } }' "out/$name.frames"
awk -F, 'NR>1 && $2!="exited" {c+=$3; n++; if ($8>h) h=$8} END {if(n) printf "cpu: %.0f%% of budget avg, worst hung-ping %sms\n", c/n, h}' "$f"
