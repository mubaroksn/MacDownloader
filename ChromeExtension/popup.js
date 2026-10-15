const dot = document.getElementById("dot");
const text = document.getElementById("text");
const enabled = document.getElementById("enabled");
const minSize = document.getElementById("minSize");

chrome.runtime.sendMessage({ type: "status" }, (res) => {
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
