(function () {
  const unwrap = (op, args) => {
    const r = JSON.parse(_native(op, JSON.stringify(args)));
    if (r.error) throw new Error(r.error);
    return r.value;
  };
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  globalThis.atob = function (s) {
    let bits = 0,
      value = 0,
      out = "";
    for (const c of s.replace(/=+$/, "")) {
      const v = alphabet.indexOf(c);
      if (v < 0) continue;
      value = (value << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((value >> bits) & 255);
      }
    }
    return out;
  };
  globalThis.btoa = function (s) {
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i),
        b = s.charCodeAt(i + 1),
        c = s.charCodeAt(i + 2);
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out +=
        alphabet[(n >> 18) & 63] +
        alphabet[(n >> 12) & 63] +
        (i + 1 < s.length ? alphabet[(n >> 6) & 63] : "=") +
        (i + 2 < s.length ? alphabet[n & 63] : "=");
    }
    return out;
  };
  globalThis.crypto = {
    getRandomValues(array) {
      const raw = atob(unwrap("crypto.random", { size: array.byteLength }));
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
      for (let i = 0; i < bytes.length; i++) bytes[i] = raw.charCodeAt(i);
      return array;
    },
    randomUUID() {
      const b = this.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 15) | 64;
      b[8] = (b[8] & 63) | 128;
      const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
      return (
        h.slice(0, 8) +
        "-" +
        h.slice(8, 12) +
        "-" +
        h.slice(12, 16) +
        "-" +
        h.slice(16, 20) +
        "-" +
        h.slice(20)
      );
    },
  };
  globalThis.performance = { now: () => Date.now() };
  globalThis.self = globalThis;
  let timerID = 0;
  const timers = new Map();
  globalThis.setTimeout = (fn, delay = 0, ...args) => {
    const id = ++timerID;
    timers.set(id, { fn, args, repeat: false });
    _scheduleTimer(id, Math.max(0, delay), false);
    return id;
  };
  globalThis.setInterval = (fn, delay = 0, ...args) => {
    const id = ++timerID;
    timers.set(id, { fn, args, repeat: true });
    _scheduleTimer(id, Math.max(1, delay), true);
    return id;
  };
  globalThis.clearTimeout = globalThis.clearInterval = (id) => {
    timers.delete(id);
    _cancelTimer(id);
  };
  globalThis.setImmediate = (fn, ...args) => setTimeout(fn, 0, ...args);
  globalThis.clearImmediate = clearTimeout;
  globalThis.queueMicrotask = (fn) => Promise.resolve().then(fn);
  globalThis.__fireTimer = (id) => {
    const t = timers.get(id);
    if (t) {
      if (!t.repeat) timers.delete(id);
      t.fn(...t.args);
    }
  };
  let requestID = 0;
  const requests = new Map();
  globalThis.__nativeFetch = (payload, signal) =>
    new Promise((resolve, reject) => {
      const id = ++requestID;
      const abort = () => {
        requests.delete(id);
        _cancelHTTP(id);
        signal?.removeEventListener("abort", abort);
        const error = new Error("Request cancelled");
        error.name = "AbortError";
        reject(error);
      };
      if (signal?.aborted) {
        abort();
        return;
      }
      signal?.addEventListener("abort", abort);
      requests.set(id, {
        resolve,
        reject,
        cleanup: () => signal?.removeEventListener("abort", abort),
      });
      _http(id, payload);
    });
  globalThis.__nativeResolve = (id, result) => {
    const request = requests.get(id);
    requests.delete(id);
    if (request) {
      request.cleanup();
      request.resolve(result);
    }
  };
  globalThis.AbortController = class {
    constructor() {
      const listeners = new Set();
      this.signal = {
        aborted: false,
        addEventListener: (_, fn) => listeners.add(fn),
        removeEventListener: (_, fn) => listeners.delete(fn),
      };
      this.abort = () => {
        this.signal.aborted = true;
        listeners.forEach((fn) => fn());
      };
    }
  };
  globalThis.URL = class {
    constructor(url, base) {
      this.parts = unwrap("url.parse", {
        url: String(url),
        base: base == null ? null : String(base),
      });
    }
    get href() {
      return (
        this.parts.protocol +
        "//" +
        this.parts.host +
        this.parts.pathname +
        this.parts.search +
        this.parts.hash
      );
    }
    get pathname() {
      return this.parts.pathname;
    }
    set pathname(v) {
      this.parts.pathname = v.startsWith("/") ? v : "/" + v;
    }
    get origin() {
      return this.parts.origin;
    }
    get hostname() {
      return this.parts.hostname;
    }
    get host() {
      return this.parts.host;
    }
    get port() {
      return this.parts.port;
    }
    get protocol() {
      return this.parts.protocol;
    }
    get search() {
      return this.parts.search;
    }
    set search(v) {
      this.parts.search = v ? (v.startsWith("?") ? v : "?" + v) : "";
    }
    get hash() {
      return this.parts.hash;
    }
    set hash(v) {
      this.parts.hash = v ? (v.startsWith("#") ? v : "#" + v) : "";
    }
    toString() {
      return this.href;
    }
    toJSON() {
      return this.href;
    }
  };
  globalThis.TextEncoder = class {
    encode(value) {
      const str = unescape(encodeURIComponent(value));
      return Uint8Array.from(str, (c) => c.charCodeAt(0));
    }
  };
  globalThis.TextDecoder = class {
    decode(value) {
      const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) : value;
      return decodeURIComponent(
        escape(Array.from(bytes || [], (c) => String.fromCharCode(c)).join("")),
      );
    }
  };
})();
