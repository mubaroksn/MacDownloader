// MacDownloader browser extension (Chrome, Edge, Brave, Arc, Dia, Vivaldi, Opera… and Firefox).
// One source for every browser: scripts/build_extensions.sh derives the Firefox manifest.
//
// Flow for every browser download:
//   1. pause it in the browser (nothing is lost),
//   2. ask the app to take over; the app resolves and probes the link first,
//   3. app accepted  -> cancel + erase it in the browser,
//      app refused   -> resume it in the browser (one-time links, POST forms, login pages…).
// Chrome runs this file alone as a service worker; Firefox loads the helpers via the manifest.
if (typeof importScripts === "function" && typeof STRINGS_EN === "undefined") {
  importScripts("strings.js", "i18n.js");
}
const langReady = loadLang();

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
  const ff = navigator.userAgent.match(/Firefox\/(\d+)/);
  if (ff) return "Firefox";
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

// Heartbeat so the app can show "extension connected" truthfully. The reply carries the
// app's language, which the extension follows.
async function hello() {
  try {
    const res = await post("/hello", { browser: browserName(), version: chrome.runtime.getManifest().version }, 1500);
    if (res && (res.lang === "id" || res.lang === "en")) await followAppLanguage(res.lang);
    return true;
  } catch {
    return false;
  }
}

async function followAppLanguage(lang) {
  const { appLang } = await chrome.storage.local.get("appLang");
  LANG = lang;
  if (appLang === lang) return;
  await chrome.storage.local.set({ appLang: lang });
  createMenu();
}

// storeId: Firefox containers/private windows keep their own cookie jar (item.cookieStoreId).
async function cookieHeader(url, storeId) {
  try {
    const cookies = await chrome.cookies.getAll(storeId ? { url, storeId } : { url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

async function handOff({ url, filename = "", referrer = "", storeId }) {
  try {
    const res = await post(
      "/add",
      {
        url,
        filename,
        referrer,
        cookie: await cookieHeader(url, storeId),
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
  const accepted = await handOff({ url, filename, referrer: item.referrer || "", storeId: item.cookieStoreId });

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

function createMenu() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "macdl-link",
      title: t("Download dengan MacDownloader"),
      contexts: ["link", "video", "audio", "image"],
    });
  });
}

async function setup() {
  await langReady;
  createMenu();
  chrome.alarms.create("macdl-heartbeat", { periodInMinutes: 0.5 });
  hello();
}

chrome.runtime.onInstalled.addListener(setup);
chrome.runtime.onStartup.addListener(setup);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "macdl-heartbeat") hello();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const url = info.linkUrl || info.srcUrl;
  if (!url || !/^https?:/i.test(url)) return;
  const ok = await handOff({ url, referrer: info.pageUrl || "", storeId: tab && tab.cookieStoreId });
  flashBadge(ok ? "✓" : "!", ok ? "#1a7f37" : "#d93025");
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "status") {
    hello().then((alive) => reply({ alive, browser: browserName() }));
    return true;
  }
});
