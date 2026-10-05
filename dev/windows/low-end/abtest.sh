#!/bin/bash
# One run that does what a person does, on either build, for comparing them:
# sit on the home page, scroll it, press Play, watch, bring up the controls.
#   ./abtest.sh <machine> <tag> <exe>
# Writes out/<machine>-<tag>.csv (cost per second), screenshots of what is on
# screen (real DWM output, not PrintWindow) and prints a summary.
cd "$(dirname "$0")"
machine=$1; tag=$2; exe=$3
name="$machine-$tag"; f="out/$name.csv"; rm -f "$f" stop "out/$name.marks"
log="$LOCALAPPDATA/Mahfin Desktop/profiles/a4bab4f497a2445682d089fd408403c2/logs/Mahfin Desktop.log"
shot() { powershell -NoProfile -File ../webview2-spike/screenshot.ps1 -Name 'Mahfin' -Out "$(cygpath -w "$PWD")/out/$name-$1.png" >/dev/null 2>&1; }
mark() { echo "$1 $(awk -F, 'END{print $1}' "$f")" >> "out/$name.marks"; }

powershell -NoProfile -File run.ps1 -Machine "$machine" -Duration 150 -Tag "$tag" -Exe "$(cygpath -w "$exe")" -ExtraArgs "--reset-graphics" >/dev/null 2>&1 &
until [ -f "$f" ] && [ "$(grep -c . "$f")" -ge 3 ]; do sleep 1; done
until node cdp.mjs eval "document.querySelectorAll('a[href^=\"/play/\"]').length" 2>/dev/null | grep -qv '^0$'; do
  sleep 1; grep -q exited "$f" && { echo "EXITED before the page loaded"; exit 1; }
done
echo "page ready at $(awk -F, 'END{print $1}' "$f") s"
sleep 5
mark idle;   echo "idle:   $(node cdp.mjs perf 10 | tr -d '\n ')"
shot home
mark scroll; echo "scroll: $(node cdp.mjs scroll)"
mark play
node cdp.mjs eval "(()=>{const a=document.querySelector('a[href^=\"/play/\"]'); a.click(); return a.getAttribute('href')})()" >/dev/null
until node cdp.mjs eval "location.pathname" 2>/dev/null | grep -q play; do sleep 1; done
sleep 30
shot play
node --input-type=module -e "
const t=await (await fetch('http://127.0.0.1:9222/json')).json(); const p=t.find(x=>x.type==='page');
const ws=new WebSocket(p.webSocketDebuggerUrl); await new Promise(r=>ws.addEventListener('open',r)); let id=0;
const send=(m,pa)=>new Promise(r=>{const i=++id; ws.addEventListener('message',e=>{const d=JSON.parse(e.data); if(d.id===i) r(d)}); ws.send(JSON.stringify({id:i,method:m,params:pa}))});
for (let i=0;i<8;i++){ await send('Input.dispatchMouseEvent',{type:'mouseMoved',x:400+i*30,y:300+i*10}); await new Promise(r=>setTimeout(r,80)); }
process.exit(0)"
sleep 0.4; shot controls
mark controls; sleep 8
echo "player: $(node cdp.mjs eval "(document.body.innerText.match(/\\d+:\\d\\d(:\\d\\d)? \\/ [\\d:]+/)||['?'])[0]")"
mark end
touch stop; while tasklist | grep -qi "Mahfin.exe"; do sleep 1; done; rm -f stop
grep -E "Using hardware decoding|VO: \[|OpenGL renderer|WebView2 runtime" "$log" | sed 's/.* - //' | sort -u | head -5
# CPU per phase, from the marks (seconds into the run).
awk -F, -v marks="out/$name.marks" '
  BEGIN { while ((getline l < marks) > 0) { split(l, w, " "); n++; ph[n]=w[1]; at[n]=w[2] } }
  NR>1 && $2!="exited" { for (i=1;i<n;i++) if ($1>=at[i] && $1<at[i+1]) { c[ph[i]]+=$2; k[ph[i]]++; if ($8>h[ph[i]]) h[ph[i]]=$8; m[ph[i]]=$5 } }
  END { for (i=1;i<n;i++) { q=ph[i]; if (k[q]) printf "%-8s cpu=%.2f cores  private=%sMB  worst-hang=%sms\n", q, c[q]/k[q], m[q], h[q]+0 } }' "$f"
