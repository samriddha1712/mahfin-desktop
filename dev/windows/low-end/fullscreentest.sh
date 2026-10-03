#!/bin/bash
# Player fullscreen, then leave it two ways:
#   back    - history back to the library: the window must come out of fullscreen
#   episode - a page load into another player: the window must stay fullscreen
# Prints the window's state after each, from the app's own log.
cd "$(dirname "$0")"
machine=${1:-host}
log="$LOCALAPPDATA/Mahfin Desktop/profiles/a4bab4f497a2445682d089fd408403c2/logs/Mahfin Desktop.log"
state() { grep -E "onVisibilityChanged: visibility=" "$log" | tail -1 | sed -E 's/.*visibility= QWindow::([A-Za-z]+).*/\1/'; }
playing() { until node cdp.mjs eval "location.pathname" 2>/dev/null | grep -q play; do sleep 1; done; sleep 6; }
f="out/$machine-fs.csv"; rm -f "$f" stop
powershell -NoProfile -File run.ps1 -Machine "$machine" -Duration 400 -Tag fs -ExtraArgs '--reset-graphics' >/dev/null 2>&1 &
until [ -f "$f" ] && [ "$(grep -c . "$f")" -ge 8 ]; do sleep 1; done
until node cdp.mjs eval "document.querySelectorAll('a[href^=\"/play/\"]').length" 2>/dev/null | grep -qv '^0$'; do sleep 1; done
ids=$(node cdp.mjs eval "[...new Set([...document.querySelectorAll('a[href^=\"/play/\"]')].map(a=>a.getAttribute('href')))].slice(0,2).join(' ')" | tr -d '"')
first=${ids%% *}; second=${ids##* }
fsbtn='button[aria-label*="ullscreen" i]'

powershell -NoProfile -File maximize.ps1
echo "== back: maximized, play $first, fullscreen, then Back   (start: $(state))"
node cdp.mjs eval "location.assign('$first'); 'go'" >/dev/null; playing
node cdp.mjs click ".mahfin-mpv-surface" >/dev/null; sleep 1; node cdp.mjs click "$fsbtn"; sleep 3; echo "  after fullscreen click: $(state)"
node cdp.mjs eval "history.back(); 'back'" >/dev/null
until node cdp.mjs eval "location.pathname" 2>/dev/null | grep -qv play; do sleep 1; done; sleep 4
echo "  on $(node cdp.mjs eval 'location.pathname'): window is $(state)   (expected: Maximized)"

echo "== episode: play $first, fullscreen, then load $second"
node cdp.mjs eval "location.assign('$first'); 'go'" >/dev/null; playing
node cdp.mjs click ".mahfin-mpv-surface" >/dev/null; sleep 1; node cdp.mjs click "$fsbtn"; sleep 3; echo "  after fullscreen click: $(state)"
node cdp.mjs eval "location.assign('$second'); 'next'" >/dev/null; sleep 2; playing
echo "  on $(node cdp.mjs eval 'location.pathname'): window is $(state)   (expected: FullScreen)"
grep -E "Request fullscreen" "$log" | sed 's/.* - //' | tail -4

touch stop; while tasklist | grep -qi "Mahfin Desktop"; do sleep 1; done; rm -f stop
