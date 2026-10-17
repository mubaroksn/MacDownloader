const dot = document.getElementById("dot");
const text = document.getElementById("text");
const enabled = document.getElementById("enabled");
const minSize = document.getElementById("minSize");

chrome.runtime.sendMessage({ type: "status" }, (res) => {
  if (document.getElementById("grant").style.display === "block") return; // permission message wins
  const alive = !!res?.alive;
  dot.className = "dot " + (alive ? "on" : "off");
  text.textContent = alive ? "Aplikasi terhubung" : "Aplikasi tidak berjalan";
});

chrome.storage.local.get(["enabled", "minSizeMB"], (s) => {
  enabled.checked = s.enabled !== false;
  minSize.value = s.minSizeMB ?? 0;
});

enabled.addEventListener("change", () => chrome.storage.local.set({ enabled: enabled.checked }));
minSize.addEventListener("change", () =>
  chrome.storage.local.set({ minSizeMB: Math.max(0, Number(minSize.value) || 0) })
);

// Firefox may install the extension without its host permission (needed for cookies and for
// talking to the app). Chromium always grants it, so the button never shows there.
const grant = document.getElementById("grant");
const ALL = { origins: ["<all_urls>"] };
chrome.permissions.contains(ALL, (has) => {
  if (has) return;
  grant.style.display = "block";
  text.textContent = "Butuh izin akses situs";
  dot.className = "dot off";
});
grant.addEventListener("click", () => {
  chrome.permissions.request(ALL, (ok) => { if (ok) window.close(); });
});
