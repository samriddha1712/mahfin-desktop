// Tiny CDP client for the page inside Mahfin Desktop (--remote-debugging-port=9222).
// node cdp.mjs eval "<expr>" | metrics | shot <file.png> | perf <seconds>
import { writeFileSync } from 'node:fs';

const targets = await (await fetch('http://127.0.0.1:9222/json')).json();
const page = targets.find(t => t.type === 'page');
if (!page) { console.log('no page target', targets); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const pending = new Map(); const events = [];
ws.addEventListener('message', m => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  else if (msg.method) events.push(msg);
});
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async expr => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  return r.result?.result?.value ?? r.result?.exceptionDetails?.exception?.description ?? r;
};
const metrics = async () => Object.fromEntries((await send('Performance.getMetrics')).result.metrics.map(m => [m.name, m.value]));

const [cmd, arg] = process.argv.slice(2);
if (cmd === 'eval') console.log(JSON.stringify(await evaluate(arg), null, 1));
else if (cmd === 'metrics') { await send('Performance.enable'); console.log(await metrics()); }
else if (cmd === 'shot') {
  const r = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(arg, Buffer.from(r.result.data, 'base64')); console.log('saved', arg);
}
else if (cmd === 'perf') {
  // How much work the page does while nobody touches it.
  await send('Performance.enable');
  const a = await metrics(); const t0 = Date.now();
  await new Promise(r => setTimeout(r, Number(arg || 10) * 1000));
  const b = await metrics(); const dt = (Date.now() - t0) / 1000;
  const d = k => ((b[k] - a[k]) / dt).toFixed(3);
  console.log(JSON.stringify({ seconds: dt, layoutsPerSec: d('LayoutCount'), recalcStylePerSec: d('RecalcStyleCount'),
    scriptSecPerSec: d('ScriptDuration'), layoutSecPerSec: d('LayoutDuration'), styleSecPerSec: d('RecalcStyleDuration'),
    taskSecPerSec: d('TaskDuration'), jsHeapMB: (b.JSHeapUsedSize / 1048576).toFixed(1), nodes: b.Nodes,
    listeners: b.JSEventListeners, frames: b.Frames }, null, 1));
}
else if (cmd === 'click') {
  // Real (trusted) mouse click on the first element matching a CSS selector —
  // fullscreen, for one, refuses anything that is not genuine input.
  const r = JSON.parse(await evaluate(`(()=>{const e=document.querySelector(${JSON.stringify(arg)}); if(!e) return 'null'; const b=e.getBoundingClientRect(); return JSON.stringify({x:b.x+b.width/2,y:b.y+b.height/2})})()`));
  if (!r) { console.log('no element for', arg); }
  else {
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased'])
      await send('Input.dispatchMouseEvent', { type, x: r.x, y: r.y, button: 'left', clickCount: 1 });
    console.log('clicked', arg, 'at', Math.round(r.x), Math.round(r.y));
  }
}
else if (cmd === 'scroll') {
  // Wheel-scroll down for ~4s; measure frames the page managed and the worst gap.
  await evaluate(`window.__f=[];(function f(t){window.__f.push(t); if(window.__f.length<2000) (window.__raf||requestAnimationFrame)(f)})(performance.now());0`);
  for (let i = 0; i < 40; i++) {
    await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 640, y: 400, deltaX: 0, deltaY: i < 20 ? 200 : -200 });
    await new Promise(r => setTimeout(r, 100));
  }
  const r = await evaluate(`(()=>{const f=window.__f; window.__f=[1e9]; const gaps=f.slice(1).map((t,i)=>t-f[i]); const dur=(f[f.length-1]-f[0])/1000; gaps.sort((a,b)=>b-a); return JSON.stringify({fps:(f.length/dur).toFixed(1), worstGapMs:gaps[0].toFixed(0), p95GapMs:gaps[Math.floor(gaps.length*0.05)].toFixed(0), over50ms:gaps.filter(g=>g>50).length})})()`);
  console.log(r);
}
ws.close(); process.exit(0);
