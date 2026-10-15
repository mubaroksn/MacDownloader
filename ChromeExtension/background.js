// MacDownloader browser extension: hands browser downloads over to the Mac app.
const API = "http://127.0.0.1:9614";
const CLIENT = { "X-MacDL-Client": "chrome-extension" };

// URLs we deliberately let the browser download itself (fallback when the app refuses).
const bypass = new Set();

async function getSettings() {
  const { enabled = true, minSizeMB = 0 } = await chrome.storage.local.get(["enabled", "minSizeMB"]);
  return { enabled, minSizeMB };
}

async function appAlive() {
  try {
    const res = await fetch(`${API}/ping`, { headers: CLIENT, signal: AbortSignal.timeout(1500) });
    return res.ok;
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

async function sendToApp({ url, filename = "", referrer = "" }) {
  try {
    const res = await fetch(`${API}/add`, {
      method: "POST",
      headers: { ...CLIENT, "Content-Type": "application/json" },
      body: JSON.stringify({
        url,
        filename,
        referrer,
        cookie: await cookieHeader(url),
        userAgent: navigator.userAgent,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (bypass.delete(url)) return;
  if (!/^https?:/i.test(url) || item.state !== "in_progress") return;

  const { enabled, minSizeMB } = await getSettings();
  if (!enabled) return;
  if (minSizeMB > 0 && item.totalBytes > 0 && item.totalBytes < minSizeMB * 1024 * 1024) return;
  if (!(await appAlive())) return; // App closed: let the browser handle it normally.

  try { await chrome.downloads.cancel(item.id); } catch {}
  try { await chrome.downloads.erase({ id: item.id }); } catch {}

  const filename = item.filename ? item.filename.split(/[\\/]/).pop() : "";
  const ok = await sendToApp({ url, filename, referrer: item.referrer || "" });
  if (!ok) {
    bypass.add(url);
    chrome.downloads.download({ url });
  }
});

function createMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "macdl-link",
      title: "Download dengan MacDownloader",
      contexts: ["link", "video", "audio", "image"],
    });
  });
}

chrome.runtime.onInstalled.addListener(createMenus);
chrome.runtime.onStartup.addListener(createMenus);

chrome.contextMenus.onClicked.addListener(async (info) => {
  const url = info.linkUrl || info.srcUrl;
  if (!url || !/^https?:/i.test(url)) return;
  const ok = await sendToApp({ url, referrer: info.pageUrl || "" });
  if (!ok) {
    chrome.action.setBadgeBackgroundColor({ color: "#d93025" });
    chrome.action.setBadgeText({ text: "!" });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 3000);
  }
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "status") {
    appAlive().then((alive) => reply({ alive }));
    return true;
  }
});
