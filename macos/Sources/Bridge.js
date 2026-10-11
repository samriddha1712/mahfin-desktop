// Injected at document start, main frame only, before any of Mahfin's scripts.
//
// Recreates what the Qt shell's nativeshell.js + QWebChannel gave the page —
// only the parts Mahfin uses (src/lib/nativeShell.ts, mpvPlayer.ts,
// appUpdate.ts in the Mahfin repo):
//
//   window.jmpInfo        version, deviceName, graphics.tier,
//                         settings.main.fullscreen (live, write-through),
//                         settingsUpdate (callbacks: (section, data))
//   window.apiPromise     resolves to { player, system, window }
//   window.initCompleted  resolves once the above are ready
//
// Calls go to Swift over WKScriptMessageHandler ("mahfin"); signals come back
// through window.__mahfinEmit(object, signal, args). The Swift side answers
// only this app's main frame on Mahfin's own addresses.
(() => {
  "use strict";
  const info = window.__mahfinInfo || {};
  delete window.__mahfinInfo;

  const post = (object, method, args) => {
    try {
      window.webkit.messageHandlers.mahfin.postMessage({ object, method, args });
    } catch (e) {
      console.error("mahfin bridge:", e);
    }
  };

  const signals = new Map();
  const signal = (object, name) => {
    const key = object + "." + name;
    if (!signals.has(key)) signals.set(key, new Set());
    const set = signals.get(key);
    return { connect: (fn) => set.add(fn), disconnect: (fn) => set.delete(fn) };
  };

  const makeObject = (object, methods, names) => {
    const o = {};
    for (const m of methods) {
      o[m] = (...args) => {
        // QWebChannel's convention: a trailing function is the reply callback.
        // Nothing Mahfin calls here returns a value, so it is answered at once.
        const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
        post(object, m, args);
        if (cb) cb();
      };
    }
    for (const s of names) o[s] = signal(object, s);
    return Object.freeze(o);
  };

  const player = makeObject(
    "player",
    ["load", "setVideoRectangle", "seekTo", "play", "pause", "stop", "setVolume", "setMuted",
     "setPlaybackRate", "setAudioStream", "setSubtitleStream", "userCommand"],
    ["playing", "paused", "buffering", "updateDuration", "positionUpdate", "finished", "error",
     "bufferedRangesUpdated", "playbackRateChanged", "stopped", "canceled"],
  );
  const system = makeObject("system", ["openExternalUrl"], []);
  const win = makeObject("window", ["setCursorVisibility", "setFullscreen"], []);

  Object.defineProperty(window, "__mahfinEmit", {
    value: (object, name, args) => {
      const set = signals.get(object + "." + name);
      if (!set) return;
      for (const fn of [...set]) {
        try { fn(...(args || [])); } catch (e) { console.error("mahfin signal", name, e); }
      }
    },
  });

  // Fullscreen: a live accessor, like the Qt shell's settings proxy. Reading it
  // gives the window's state; writing it asks the window to change; any change
  // however it happened (green button, Esc, the menu) is reported to every
  // settingsUpdate callback.
  let fullscreen = !!info.fullscreen;
  const settingsUpdate = [];
  const main = {};
  Object.defineProperty(main, "fullscreen", {
    enumerable: true,
    get: () => fullscreen,
    set: (v) => { post("window", "setFullscreen", [!!v]); },
  });
  Object.defineProperty(window, "__mahfinFullscreen", {
    value: (v) => {
      fullscreen = !!v;
      for (const cb of [...settingsUpdate]) {
        try { cb("main", { fullscreen }); } catch (e) { console.error(e); }
      }
    },
  });

  window.jmpInfo = {
    version: info.version || "0.0.0",
    deviceName: info.deviceName || "Mac",
    userAgent: navigator.userAgent,
    mode: "desktop",
    graphics: { tier: "normal", softwareRenderer: false, adapter: "", memoryMB: 0, cores: 0, reasons: [] },
    settings: { main },
    settingsUpdate,
  };

  const api = Object.freeze({ player, system, window: win });
  window.api = api;
  window.apiPromise = Promise.resolve(api);
  window.initCompleted = Promise.resolve();
})();
