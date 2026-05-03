const state = {
  latest: null,
  history: [],
};

const el = {
  broker: document.getElementById("broker"),
  alarm: document.getElementById("alarm"),
  updated: document.getElementById("updated"),
  temperature: document.getElementById("temperature"),
  humidity: document.getElementById("humidity"),
  chart: document.getElementById("chart"),
};

function fmt(value, digits = 1) {
  return Number.isFinite(value) ? value.toFixed(digits) : "--.-";
}

function setPill(node, enabled, warn = false) {
  node.classList.toggle("on", enabled && !warn);
  node.classList.toggle("warn", enabled && warn);
  node.classList.toggle("off", !enabled);
}

function renderStatus(status) {
  if (!status) return;
  state.latest = status;
  el.temperature.textContent = fmt(status.temperature);
  el.humidity.textContent = fmt(status.humidity);
  el.updated.textContent = status.receivedAt
    ? `Ostatni pomiar: ${new Date(status.receivedAt).toLocaleString("pl-PL")}`
    : `Uptime: ${Math.round((status.uptimeMs || 0) / 1000)} s`;
  el.alarm.textContent = status.alarm ? "Alarm" : "Brak alarmu";
  setPill(el.alarm, Boolean(status.alarm), Boolean(status.alarm));

  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.classList.toggle("active", button.dataset.mode === status.mode);
  });
  document.querySelectorAll("[data-relay]").forEach((button) => {
    button.classList.toggle("active", Boolean(status.relays?.[button.dataset.relay]));
  });
}

function renderChart() {
  const canvas = el.chart;
  const ctx = canvas.getContext("2d");
  const w = canvas.width;
  const h = canvas.height;
  ctx.clearRect(0, 0, w, h);
  ctx.fillStyle = "#fbfcfb";
  ctx.fillRect(0, 0, w, h);

  const data = state.history.slice(-120);
  if (data.length < 2) return;

  const temps = data.map((p) => p.temperature).filter(Number.isFinite);
  const hums = data.map((p) => p.humidity).filter(Number.isFinite);
  const minT = Math.min(...temps, 0);
  const maxT = Math.max(...temps, 30);
  const minH = Math.min(...hums, 0);
  const maxH = Math.max(...hums, 100);
  const pad = 28;

  ctx.strokeStyle = "#d8ded9";
  ctx.lineWidth = 1;
  for (let i = 0; i < 4; i++) {
    const y = pad + ((h - pad * 2) * i) / 3;
    ctx.beginPath();
    ctx.moveTo(pad, y);
    ctx.lineTo(w - pad, y);
    ctx.stroke();
  }

  function line(key, color, min, max) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.beginPath();
    data.forEach((point, index) => {
      const x = pad + ((w - pad * 2) * index) / (data.length - 1);
      const y = h - pad - ((h - pad * 2) * (point[key] - min)) / Math.max(max - min, 1);
      if (index === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
  }

  line("humidity", "#2f7bbd", minH, maxH);
  line("temperature", "#c24b3a", minT, maxT);
}

async function loadInitial() {
  const [statusResponse, historyResponse] = await Promise.all([
    fetch("/api/status"),
    fetch("/api/history?limit=500"),
  ]);
  const status = await statusResponse.json();
  state.history = await historyResponse.json();
  setPill(el.broker, Boolean(status.brokerConnected));
  renderStatus(status.status);
  renderChart();
}

document.querySelectorAll("[data-mode]").forEach((button) => {
  button.addEventListener("click", () => {
    fetch("/api/mode", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: button.dataset.mode }),
    });
  });
});

document.querySelectorAll("[data-relay]").forEach((button) => {
  button.addEventListener("click", () => {
    const relay = button.dataset.relay;
    const next = !button.classList.contains("active");
    fetch("/api/manual", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ [relay]: next }),
    });
  });
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

const events = new EventSource("/api/events");
events.addEventListener("broker", (event) => {
  setPill(el.broker, JSON.parse(event.data).connected);
});
events.addEventListener("status", (event) => {
  const status = JSON.parse(event.data);
  renderStatus(status);
  if (status.sensorOk) {
    state.history.push({
      ts: status.receivedAt || new Date().toISOString(),
      temperature: status.temperature,
      humidity: status.humidity,
      alarm: status.alarm,
      alarmMessage: status.alarmMessage,
      relays: status.relays,
    });
    state.history = state.history.slice(-500);
    renderChart();
  }
});

loadInitial().catch(() => {});
