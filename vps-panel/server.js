import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import mqtt from "mqtt";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(__dirname, "public");
const dataDir = process.env.DATA_DIR || path.join(__dirname, "data");
const firmwareDir = process.env.FIRMWARE_DIR || path.join(__dirname, "releases");
const historyFile = path.join(dataDir, "history.jsonl");

const PORT = Number(process.env.PORT || 30345);
const MQTT_URL = process.env.MQTT_URL || "mqtt://127.0.0.1:20345";
const MQTT_USER = process.env.MQTT_USER || "dojrzewalnia";
const MQTT_PASSWORD = process.env.MQTT_PASSWORD || "";
const BACKEND_URL = process.env.BACKEND_URL || "http://127.0.0.1:20346";
const DEFAULT_DEVICE_ID = process.env.DEVICE_ID || "dojrzewalnia-01";
const PANEL_USER = process.env.PANEL_USER || "admin";
const PANEL_PASSWORD = process.env.PANEL_PASSWORD || "";

const backendRoutes = new Set([
  "GET /health",
  "POST /register",
  "POST /login",
  "GET /me",
  "POST /devices",
  "GET /devices",
  "GET /devices/available",
  "GET /devices/discovered",
  "GET /discovered",
  "GET /mode",
  "POST /mode",
  "POST /device_data",
  "GET /latest",
  "GET /stream",
  "POST /control",
  "POST /auto/run",
  "GET /admin/users",
  "GET /admin/devices",
  "POST /fcm/token",
  "POST /telemetry",
  "GET /history",
  "POST /ai/control",
  "POST /ai/device/state",
  "GET /ai/device/settings",
  "GET /scenes",
  "POST /scenes/apply",
  "POST /alerts/evaluate",
]);

fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(firmwareDir, { recursive: true });

const latestByDevice = new Map();
let mqttConnected = false;
const clients = new Set();

function sendEvent(type, payload) {
  const frame = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  for (const response of clients) {
    response.write(frame);
  }
}

function parseNumericPayload(payload) {
  const value = Number(payload.toString());
  return Number.isFinite(value) ? value : payload.toString();
}

function publishMqtt(topic, value, options = {}) {
  mqttClient.publish(topic, value, options);
}

function publishSetting(topic, value) {
  mqttClient.publish(topic, value, { qos: 1, retain: true });
}

function updateDeviceSettingStatus(topic, payload) {
  const match = topic.match(/^devices\/([^/]+)\/curing\/set\/([^/]+)$/);
  if (!match) {
    return false;
  }

  const [, deviceId, settingKey] = match;
  const previousStatus = latestByDevice.get(deviceId) || {};
  const parsedValue = parseNumericPayload(payload);
  const nextStatus = {
    ...previousStatus,
    deviceId,
    receivedAt: new Date().toISOString(),
  };

  switch (settingKey) {
    case "temp":
      nextStatus.target_temp = parsedValue;
      break;
    case "hum":
      nextStatus.target_humidity = parsedValue;
      break;
    case "temp_hysteresis":
      nextStatus.temp_hysteresis = parsedValue;
      break;
    case "hum_hysteresis":
      nextStatus.hum_hysteresis = parsedValue;
      break;
    default:
      return false;
  }

  latestByDevice.set(deviceId, nextStatus);
  sendEvent("status", nextStatus);
  sendEvent("devices", knownDevices());
  return true;
}

function appendHistory(status) {
  if (!status || !status.sensorOk) {
    return;
  }

  const row = {
    deviceId: status.deviceId || DEFAULT_DEVICE_ID,
    ts: new Date().toISOString(),
    temperature: status.temperature,
    humidity: status.humidity,
    alarm: Boolean(status.alarm),
    alarmMessage: status.alarmMessage || "",
    relays: status.relays || {},
  };
  fs.appendFile(historyFile, `${JSON.stringify(row)}\n`, () => {});
}

function readHistory(deviceId = DEFAULT_DEVICE_ID, limit = 500) {
  if (!fs.existsSync(historyFile)) {
    return [];
  }

  const lines = fs.readFileSync(historyFile, "utf8").trim().split("\n").filter(Boolean);
  return lines.map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return null;
    }
  }).filter((row) => {
    if (!row) return false;
    return (row.deviceId || DEFAULT_DEVICE_ID) === deviceId;
  }).slice(-limit);
}

function knownDevices() {
  const devices = new Map();
  for (const [id, status] of latestByDevice.entries()) {
    devices.set(id, {
      id,
      name: status.name || id,
      online: true,
      lastSeen: status.receivedAt || null,
      alarm: Boolean(status.alarm),
      temperature: status.temperature,
      humidity: status.humidity,
    });
  }

  devices.set(DEFAULT_DEVICE_ID, devices.get(DEFAULT_DEVICE_ID) || {
    id: DEFAULT_DEVICE_ID,
    name: DEFAULT_DEVICE_ID,
    online: false,
    lastSeen: null,
    alarm: false,
  });

  return Array.from(devices.values()).sort((a, b) => a.id.localeCompare(b.id));
}

function contentType(filePath) {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".js")) return "application/javascript; charset=utf-8";
  if (filePath.endsWith(".json")) return "application/json; charset=utf-8";
  if (filePath.endsWith(".svg")) return "image/svg+xml";
  return "application/octet-stream";
}

function sendJson(response, data, status = 200) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(data));
}

function tryServeStaticFile(response, baseDir, requestedPathname) {
  const requested = requestedPathname === "/" ? "/index.html" : requestedPathname;
  const filePath = path.normalize(path.join(baseDir, requested));
  if (!filePath.startsWith(baseDir) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    return false;
  }

  response.writeHead(200, {
    "content-type": contentType(filePath),
    "cache-control": "no-cache",
  });
  fs.createReadStream(filePath).pipe(response);
  return true;
}

async function isAuthorized(request) {
  if (!PANEL_PASSWORD) {
    return true;
  }
  const header = request.headers.authorization || "";
  if (!header.startsWith("Basic ")) {
    return false;
  }
  const decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  if (decoded === `${PANEL_USER}:${PANEL_PASSWORD}`) {
    return true;
  }

  const separatorIndex = decoded.indexOf(":");
  if (separatorIndex <= 0) {
    return false;
  }

  try {
    const backendResponse = await fetch(new URL("/login", BACKEND_URL), {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify({
        email: decoded.slice(0, separatorIndex),
        password: decoded.slice(separatorIndex + 1),
      }),
    });
    return backendResponse.ok;
  } catch {
    return false;
  }
}

function requestAuth(response) {
  response.writeHead(401, {
    "www-authenticate": 'Basic realm="Dojrzewalnia"',
    "content-type": "text/plain; charset=utf-8",
  });
  response.end("Unauthorized");
}

function shouldProxyToBackend(request, url) {
  if (backendRoutes.has(`${request.method} ${url.pathname}`)) {
    return true;
  }

  return request.method === "DELETE" && url.pathname.startsWith("/devices/");
}

function proxyToBackend(request, response, url) {
  const targetUrl = new URL(`${url.pathname}${url.search}`, BACKEND_URL);
  const headers = { ...request.headers, host: targetUrl.host };

  const proxyRequest = http.request(
    targetUrl,
    {
      method: request.method,
      headers,
    },
    (proxyResponse) => {
      response.writeHead(proxyResponse.statusCode || 502, proxyResponse.headers);
      proxyResponse.pipe(response);
    },
  );

  proxyRequest.on("error", () => {
    sendJson(response, { error: "Backend unavailable" }, 502);
  });

  if (request.method === "GET" || request.method === "HEAD") {
    proxyRequest.end();
    return;
  }

  request.pipe(proxyRequest);
}

function publishControl(pathname, body, response) {
  try {
    const payload = body ? JSON.parse(body) : {};
    const deviceId = String(payload.deviceId || DEFAULT_DEVICE_ID).trim() || DEFAULT_DEVICE_ID;
    const topicRoot = `devices/${deviceId}`;
    if (pathname === "/api/mode") {
      const mode = String(payload.mode || "auto");
      publishMqtt(`${topicRoot}/control/mode`, mode);
      sendJson(response, { ok: true, deviceId, mode });
      return;
    }
    if (pathname === "/api/manual") {
      for (const key of ["cooling", "humidifier", "dehumidifier", "fan"]) {
        if (Object.prototype.hasOwnProperty.call(payload, key)) {
          publishMqtt(`${topicRoot}/control/${key}`, payload[key] ? "true" : "false");
        }
      }
      sendJson(response, { ok: true, deviceId });
      return;
    }
    if (pathname === "/api/targets") {
      const rawTemp = payload.targetTemp ?? payload.target_temp;
      const rawHumidity = payload.targetHumidity ?? payload.target_humidity;
      const rawTempHysteresis = payload.tempHysteresis ?? payload.temp_hysteresis;
      const rawHumHysteresis = payload.humHysteresis ?? payload.hum_hysteresis;
      const hasTemp = rawTemp !== undefined;
      const hasHumidity = rawHumidity !== undefined;
      const hasTempHysteresis = rawTempHysteresis !== undefined;
      const hasHumHysteresis = rawHumHysteresis !== undefined;

      if (!hasTemp && !hasHumidity && !hasTempHysteresis && !hasHumHysteresis) {
        sendJson(response, { error: "Missing target values" }, 400);
        return;
      }

      const previousStatus = latestByDevice.get(deviceId) || {};
      const currentTargetTemp = Number(
        hasTemp
          ? rawTemp
          : previousStatus.target_temp ?? previousStatus.temperature ?? previousStatus.temp,
      );
      const currentTargetHumidity = Number(
        hasHumidity
          ? rawHumidity
          : previousStatus.target_humidity ?? previousStatus.humidity ?? previousStatus.hum,
      );

      if (hasTemp) {
        const tempValue = Number(rawTemp);
        if (!Number.isFinite(tempValue)) {
          sendJson(response, { error: "targetTemp must be numeric" }, 400);
          return;
        }
        publishSetting(`${topicRoot}/curing/set/temp`, tempValue.toFixed(1));
      }

      let normalizedTempHysteresis = null;
      if (hasTempHysteresis) {
        normalizedTempHysteresis = Number(rawTempHysteresis);
        if (!Number.isFinite(normalizedTempHysteresis) || normalizedTempHysteresis < 0) {
          sendJson(response, { error: "tempHysteresis must be a non-negative number" }, 400);
          return;
        }
        if (!Number.isFinite(currentTargetTemp)) {
          sendJson(response, { error: "targetTemp is required when tempHysteresis is set for the first time" }, 400);
          return;
        }

        publishSetting(`${topicRoot}/curing/set/temp_hysteresis`, normalizedTempHysteresis.toFixed(1));
      }

      if (hasHumidity) {
        const humidityValue = Number(rawHumidity);
        if (!Number.isFinite(humidityValue)) {
          sendJson(response, { error: "targetHumidity must be numeric" }, 400);
          return;
        }
        publishSetting(`${topicRoot}/curing/set/hum`, humidityValue.toFixed(0));
      }

      let normalizedHumHysteresis = null;
      if (hasHumHysteresis) {
        normalizedHumHysteresis = Number(rawHumHysteresis);
        if (!Number.isFinite(normalizedHumHysteresis) || normalizedHumHysteresis < 0) {
          sendJson(response, { error: "humHysteresis must be a non-negative number" }, 400);
          return;
        }
        if (!Number.isFinite(currentTargetHumidity)) {
          sendJson(response, { error: "targetHumidity is required when humHysteresis is set for the first time" }, 400);
          return;
        }

        publishSetting(`${topicRoot}/curing/set/hum_hysteresis`, normalizedHumHysteresis.toFixed(1));
      }

      const targetTemp = hasTemp ? Number(rawTemp) : previousStatus.target_temp ?? null;
      const tempHysteresis = hasTempHysteresis
        ? normalizedTempHysteresis
        : previousStatus.temp_hysteresis ?? null;
      const targetHumidity = hasHumidity ? Number(rawHumidity) : previousStatus.target_humidity ?? null;
      const humHysteresis = hasHumHysteresis
        ? normalizedHumHysteresis
        : previousStatus.hum_hysteresis ?? null;

      latestByDevice.set(deviceId, {
        ...previousStatus,
        deviceId,
        receivedAt: new Date().toISOString(),
        ...(hasTemp ? { target_temp: Number(rawTemp) } : {}),
        ...(tempHysteresis !== null ? { temp_hysteresis: tempHysteresis } : {}),
        ...(hasHumidity ? { target_humidity: Number(rawHumidity) } : {}),
        ...(humHysteresis !== null ? { hum_hysteresis: humHysteresis } : {}),
      });

      sendJson(response, {
        ok: true,
        deviceId,
        targetTemp: hasTemp ? Number(rawTemp) : null,
        targetHumidity: hasHumidity ? Number(rawHumidity) : null,
        tempHysteresis,
        humHysteresis,
      });
      return;
    }
    sendJson(response, { error: "Unknown command" }, 404);
  } catch {
    sendJson(response, { error: "Invalid JSON" }, 400);
  }
}

const mqttClient = mqtt.connect(MQTT_URL, {
  username: MQTT_USER,
  password: MQTT_PASSWORD,
  reconnectPeriod: 3000,
  clientId: `panel-${Math.random().toString(16).slice(2)}`,
});

mqttClient.on("connect", () => {
  mqttConnected = true;
  mqttClient.subscribe("devices/+/data");
  mqttClient.subscribe("devices/+/curing/set/+");
  sendEvent("broker", { connected: true });
});

mqttClient.on("close", () => {
  mqttConnected = false;
  sendEvent("broker", { connected: false });
});

mqttClient.on("message", (topic, payload) => {
  if (updateDeviceSettingStatus(topic, payload)) {
    return;
  }

  const match = topic.match(/^devices\/([^/]+)\/data$/);
  if (!match) {
    return;
  }
  try {
    const deviceId = match[1];
    const status = JSON.parse(payload.toString());
    const mergedStatus = {
      ...(latestByDevice.get(deviceId) || {}),
      ...status,
      deviceId: status.deviceId || deviceId,
      receivedAt: new Date().toISOString(),
    };
    latestByDevice.set(deviceId, mergedStatus);
    appendHistory(mergedStatus);
    sendEvent("status", mergedStatus);
    sendEvent("devices", knownDevices());
  } catch {
    // Ignore malformed telemetry.
  }
});

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const proxyToBackendRoute = shouldProxyToBackend(request, url);

  if (url.pathname.startsWith("/firmware/")) {
    const firmwarePath = url.pathname.slice("/firmware".length) || "/";
    if (tryServeStaticFile(response, firmwareDir, firmwarePath)) {
      return;
    }

    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  if (!proxyToBackendRoute && !(await isAuthorized(request))) {
    requestAuth(response);
    return;
  }

  if (proxyToBackendRoute) {
    proxyToBackend(request, response, url);
    return;
  }

  if (url.pathname === "/api/status") {
    const deviceId = url.searchParams.get("device") || DEFAULT_DEVICE_ID;
    sendJson(response, {
      brokerConnected: mqttConnected,
      deviceId,
      status: latestByDevice.get(deviceId) || null,
      devices: knownDevices(),
    });
    return;
  }

  if (url.pathname === "/api/devices") {
    sendJson(response, knownDevices());
    return;
  }

  if (url.pathname === "/api/history") {
    const deviceId = url.searchParams.get("device") || DEFAULT_DEVICE_ID;
    const limit = Math.min(Number(url.searchParams.get("limit") || 500), 5000);
    sendJson(response, readHistory(deviceId, limit));
    return;
  }

  if (url.pathname === "/api/events") {
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    clients.add(response);
    response.write(`event: broker\ndata: ${JSON.stringify({ connected: mqttConnected })}\n\n`);
    response.write(`event: devices\ndata: ${JSON.stringify(knownDevices())}\n\n`);
    for (const status of latestByDevice.values()) {
      response.write(`event: status\ndata: ${JSON.stringify(status)}\n\n`);
    }
    request.on("close", () => clients.delete(response));
    return;
  }

  if (request.method === "POST" && ["/api/mode", "/api/manual", "/api/targets"].includes(url.pathname)) {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 8192) request.destroy();
    });
    request.on("end", () => publishControl(url.pathname, body, response));
    return;
  }

  if (!tryServeStaticFile(response, publicDir, url.pathname)) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Dojrzewalnia panel listening on ${PORT}`);
});
