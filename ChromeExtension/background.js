// MacDownloader browser extension (Chrome, Edge, Brave, Arc, Dia, Vivaldi, Opera…).
//
// Flow for every browser download:
//   1. pause it in the browser (nothing is lost),
//   2. ask the app to take over; the app resolves and probes the link first,
//   3. app accepted  -> cancel + erase it in the browser,
//      app refused   -> resume it in the browser (one-time links, POST forms, login pages…).
const API = "http://127.0.0.1:9614";
const CLIENT = { "X-MacDL-Client": "chrome-extension" };
const HANDOFF_TIMEOUT_MS = 25000;

// URLs we deliberately leave to the browser (e.g. after the app refused them).
const bypass = new Set();

async function getSettings() {
  const { enabled = true, minSizeMB = 0 } = await chrome.storage.local.get(["enabled", "minSizeMB"]);
  return { enabled, minSizeMB };
}

function browserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const named = brands.map((b) => b.brand).filter((b) => !/Not.?A.?Brand|Chromium/i.test(b));
  if (named.length) return named[0];
  const ua = navigator.userAgent;
  if (/Edg\//.test(ua)) return "Microsoft Edge";
  if (/OPR\//.test(ua)) return "Opera";
  return "Chromium";
}

async function post(path, body, timeoutMs = 3000) {
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { ...CLIENT, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  return res.json().catch(() => ({}));
}

// Heartbeat so the app can show "extension connected" truthfully.
async function hello() {
  try {
    await post("/hello", { browser: browserName(), version: chrome.runtime.getManifest().version }, 1500);
    return true;
  } catch {
    return false;
  }
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

async function handOff({ url, filename = "", referrer = "" }) {
  try {
    const res = await post(
      "/add",
      {
        url,
        filename,
        referrer,
        cookie: await cookieHeader(url),
        userAgent: navigator.userAgent,
        handoff: true,
      },
      HANDOFF_TIMEOUT_MS
    );
    return res && res.ok === true && res.accepted !== false;
  } catch {
    return false;
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (bypass.delete(url)) return;
  // blob:/data:/file: exist only inside the browser; the app cannot fetch them.
  if (!/^https?:/i.test(url) || item.state !== "in_progress") return;

  const { enabled, minSizeMB } = await getSettings();
  if (!enabled) return;
  if (minSizeMB > 0 && item.totalBytes > 0 && item.totalBytes < minSizeMB * 1024 * 1024) return;
  if (!(await hello())) return; // app not running: the browser keeps the download

  try { await chrome.downloads.pause(item.id); } catch {}

  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : "";
  const accepted = await handOff({ url, filename, referrer: item.referrer || "" });

  if (accepted) {
    try { await chrome.downloads.cancel(item.id); } catch {}
    try { await chrome.downloads.erase({ id: item.id }); } catch {}
    flashBadge("✓", "#1a7f37");
  } else {
    try { await chrome.downloads.resume(item.id); } catch {
      bypass.add(url);
      chrome.downloads.download({ url });
    }
  }
});

function flashBadge(text, color) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2500);
}

function setup() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "macdl-link",
      title: "Download dengan MacDownloader",
      contexts: ["link", "video", "audio", "image"],
    });
  });
  chrome.alarms.create("macdl-heartbeat", { periodInMinutes: 0.5 });
  hello();
}

chrome.runtime.onInstalled.addListener(setup);
chrome.runtime.onStartup.addListener(setup);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "macdl-heartbeat") hello();
});

chrome.contextMenus.onClicked.addListener(async (info) => {
  const url = info.linkUrl || info.srcUrl;
  if (!url || !/^https?:/i.test(url)) return;
  const ok = await handOff({ url, referrer: info.pageUrl || "" });
  flashBadge(ok ? "✓" : "!", ok ? "#1a7f37" : "#d93025");
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "status") {
    hello().then((alive) => reply({ alive, browser: browserName() }));
    return true;
  }
});
