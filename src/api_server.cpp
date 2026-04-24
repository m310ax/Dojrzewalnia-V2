#include <Arduino.h>
#include <WebServer.h>

#include "api_server.h"
#include "config.h"
#include "mqtt_manager.h"
#include "sensors.h"
#include "wifi_manager.h"

namespace {
WebServer server(80);
float latestTemp = 0.0F;
float latestHum = 0.0F;
unsigned long lastAppContact = 0;

bool relayOn(int pin) {
  return digitalRead(pin) == HIGH;
}

const char* getClimateState() {
  if (relayOn(RELAY_COOL)) {
    return "Chłodzenie";
  }
  if (relayOn(RELAY_HUM)) {
    return "Nawilżanie";
  }
  if (latestTemp < getTempMin()) {
    return "Za zimno";
  }
  if (latestTemp > getTempMax()) {
    return "Za ciepło";
  }
  if (latestHum < getHumMin()) {
    return "Za sucho";
  }
  if (latestHum > getHumMax()) {
    return "Za wilgotno";
  }
  return "Stabilizacja";
}

const char kDashboardHtml[] PROGMEM = R"HTML(
<!DOCTYPE html>
<html lang="pl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Dojrzewalnia</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Segoe UI, sans-serif; background: linear-gradient(180deg, #172026, #0f1418); color: #eef6fb; }
    .wrap { max-width: 760px; margin: 0 auto; padding: 24px 16px 40px; }
    .hero { padding: 18px 20px; border-radius: 18px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.08); }
    .grid { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-top: 16px; }
    .card { padding: 16px; border-radius: 16px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.07); }
    .label { color: #9eb4c2; font-size: 14px; margin-bottom: 8px; }
    .value { font-size: 28px; font-weight: 700; }
    .range { font-size: 20px; font-weight: 600; }
    .meta { margin-top: 18px; display: flex; flex-wrap: wrap; gap: 8px; }
    .chip { padding: 8px 12px; border-radius: 999px; background: rgba(255,255,255,0.08); font-size: 14px; }
    .form { margin-top: 18px; display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); }
    label { display: block; font-size: 14px; color: #9eb4c2; margin-bottom: 6px; }
    input { width: 100%; box-sizing: border-box; padding: 12px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.14); background: rgba(9,12,15,0.65); color: #eef6fb; }
    .actions { margin-top: 12px; display: flex; gap: 10px; flex-wrap: wrap; }
    button { padding: 12px 16px; border: 0; border-radius: 12px; background: #53b3cb; color: #081217; font-weight: 700; cursor: pointer; }
    button.secondary { background: rgba(255,255,255,0.10); color: #eef6fb; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="hero">
      <h1 style="margin:0 0 8px; font-size: 30px;">Panel dojrzewalni</h1>
      <div id="statusText">Ładowanie danych...</div>
      <div class="meta">
        <div class="chip" id="ipChip">IP: -</div>
        <div class="chip" id="profileChip">Profil: -</div>
        <div class="chip" id="wifiChip">WiFi: -</div>
        <div class="chip" id="sensorChip">Czujnik: -</div>
        <div class="chip" id="modeChip">Tryb: -</div>
      </div>
    </div>
    <div class="grid">
      <div class="card"><div class="label">Temperatura</div><div class="value" id="tempVal">--.-°C</div></div>
      <div class="card"><div class="label">Wilgotność</div><div class="value" id="humVal">--%</div></div>
      <div class="card"><div class="label">Zakres temperatury</div><div class="range" id="tempRangeVal">--.- do --.-°C</div></div>
      <div class="card"><div class="label">Zakres wilgotności</div><div class="range" id="humRangeVal">-- do --%</div></div>
      <div class="card"><div class="label">Przekaźnik chłodzenia</div><div class="range" id="coolRelayVal">-</div></div>
      <div class="card"><div class="label">Przekaźnik nawilżania</div><div class="range" id="humRelayVal">-</div></div>
      <div class="card"><div class="label">Wentylator</div><div class="range" id="fanRelayVal">-</div></div>
      <div class="card"><div class="label">Stan pracy</div><div class="range" id="climateStateVal">-</div></div>
    </div>
    <div class="hero" style="margin-top:16px;">
      <h2 style="margin:0 0 10px; font-size:22px;">Ustaw zakresy</h2>
      <div class="form">
        <div><label for="tempMinInput">Temperatura od</label><input id="tempMinInput" type="number" min="0" max="25" step="0.1"></div>
        <div><label for="tempMaxInput">Temperatura do</label><input id="tempMaxInput" type="number" min="0" max="25" step="0.1"></div>
        <div><label for="humMinInput">Wilgotność od</label><input id="humMinInput" type="number" min="50" max="100" step="1"></div>
        <div><label for="humMaxInput">Wilgotność do</label><input id="humMaxInput" type="number" min="50" max="100" step="1"></div>
      </div>
      <div class="actions">
        <button id="saveRangesBtn" type="button">Zapisz zakresy</button>
        <button id="reloadBtn" class="secondary" type="button">Odśwież</button>
      </div>
    </div>
  </div>
  <script>
    function formatNumber(value, digits) {
      return Number(value).toFixed(digits);
    }

    function setInputValueIfIdle(id, value, digits) {
      const element = document.getElementById(id);
      if (document.activeElement !== element) {
        element.value = formatNumber(value, digits);
      }
    }

    function relayText(state) {
      return state ? 'WŁĄCZONY' : 'WYŁĄCZONY';
    }

    async function refresh() {
      try {
        const response = await fetch('/api/status', { cache: 'no-store' });
        const data = await response.json();
        document.getElementById('tempVal').textContent = `${formatNumber(data.temp ?? 0, 1)}°C`;
        document.getElementById('humVal').textContent = `${formatNumber(data.humidity ?? 0, 0)}%`;
        document.getElementById('tempRangeVal').textContent = `${formatNumber(data.tempMin ?? 0, 1)} do ${formatNumber(data.tempMax ?? 25, 1)}°C`;
        document.getElementById('humRangeVal').textContent = `${formatNumber(data.humMin ?? 50, 0)} do ${formatNumber(data.humMax ?? 100, 0)}%`;
        document.getElementById('ipChip').textContent = `IP: ${data.ip ?? '-'}`;
        document.getElementById('profileChip').textContent = `Profil: ${data.profile ?? '-'}`;
        document.getElementById('wifiChip').textContent = `WiFi: ${(data.wifiConnected ? 'połączone' : 'offline')}`;
        document.getElementById('sensorChip').textContent = `Czujnik: ${(data.sensorConnected ? 'online' : 'offline')}`;
        document.getElementById('modeChip').textContent = `Tryb: ${data.climateState ?? '-'}`;
        document.getElementById('coolRelayVal').textContent = relayText(data.relayCool);
        document.getElementById('humRelayVal').textContent = relayText(data.relayHum);
        document.getElementById('fanRelayVal').textContent = relayText(data.relayFan);
        document.getElementById('climateStateVal').textContent = data.climateState ?? '-';
        setInputValueIfIdle('tempMinInput', data.tempMin ?? 0, 1);
        setInputValueIfIdle('tempMaxInput', data.tempMax ?? 25, 1);
        setInputValueIfIdle('humMinInput', data.humMin ?? 50, 0);
        setInputValueIfIdle('humMaxInput', data.humMax ?? 100, 0);
        document.getElementById('statusText').textContent = 'Zakresy i pomiary odświeżają się automatycznie.';
      } catch (error) {
        document.getElementById('statusText').textContent = 'Brak połączenia z API.';
      }
    }

    async function saveRanges() {
      const params = new URLSearchParams({
        temp_min: document.getElementById('tempMinInput').value,
        temp_max: document.getElementById('tempMaxInput').value,
        hum_min: document.getElementById('humMinInput').value,
        hum_max: document.getElementById('humMaxInput').value,
      });

      try {
        const response = await fetch(`/api/control?${params.toString()}`, { method: 'GET', cache: 'no-store' });
        if (!response.ok) {
          throw new Error('save failed');
        }
        document.getElementById('statusText').textContent = 'Zakresy zapisane.';
        refresh();
      } catch (error) {
        document.getElementById('statusText').textContent = 'Nie udało się zapisać zakresów.';
      }
    }

    document.getElementById('saveRangesBtn').addEventListener('click', saveRanges);
    document.getElementById('reloadBtn').addEventListener('click', refresh);
    refresh();
    setInterval(refresh, 2000);
  </script>
</body>
</html>
)HTML";

void markAppContact() {
  lastAppContact = millis();
}

void handleDashboard() {
  server.send(200, "text/html; charset=utf-8", kDashboardHtml);
}

void handleStatus() {
  markAppContact();

  String payload = "{";
  payload += "\"temp\":" + String(latestTemp, 1) + ",";
  payload += "\"humidity\":" + String(latestHum, 1) + ",";
  payload += "\"tempMin\":" + String(getTempMin(), 1) + ",";
  payload += "\"tempMax\":" + String(getTempMax(), 1) + ",";
  payload += "\"humMin\":" + String(getHumMin(), 1) + ",";
  payload += "\"humMax\":" + String(getHumMax(), 1) + ",";
  payload += "\"targetTemp\":" + String(getTargetTemp(), 1) + ",";
  payload += "\"targetHum\":" + String(getTargetHum(), 1) + ",";
  payload += "\"hysteresis\":" + String(getHysteresis(), 1) + ",";
  payload += "\"airTime\":" + String(getAirTime(), 1) + ",";
  payload += "\"airInterval\":" + String(getAirInterval(), 1) + ",";
  payload += "\"profile\":\"" + getProfile() + "\",";
  payload += "\"ip\":\"" + String(getLocalIp()) + "\",";
  payload += "\"relayCool\":" + String(relayOn(RELAY_COOL) ? "true" : "false") + ",";
  payload += "\"relayHum\":" + String(relayOn(RELAY_HUM) ? "true" : "false") + ",";
  payload += "\"relayFan\":" + String(relayOn(RELAY_FAN) ? "true" : "false") + ",";
  payload += "\"climateState\":\"" + String(getClimateState()) + "\",";
  payload += "\"wifiConnected\":" + String(isWiFiConnected() ? "true" : "false") + ",";
  payload += "\"mqttConnected\":" + String(isMqttConnected() ? "true" : "false") + ",";
  payload += "\"sensorConnected\":" + String(isSensorConnected() ? "true" : "false") + ",";
  payload += "\"appConnected\":" + String(isAppConnected() ? "true" : "false");
  payload += "}";

  server.send(200, "application/json", payload);
}

void handleControl() {
  markAppContact();

  if (server.hasArg("temp")) {
    setTargetTemp(server.arg("temp").toFloat());
  }
  if (server.hasArg("temp_min") || server.hasArg("temp_max")) {
    const float minValue = server.hasArg("temp_min") ? server.arg("temp_min").toFloat() : getTempMin();
    const float maxValue = server.hasArg("temp_max") ? server.arg("temp_max").toFloat() : getTempMax();
    setTempRange(minValue, maxValue);
  }
  if (server.hasArg("hum")) {
    setTargetHum(server.arg("hum").toFloat());
  }
  if (server.hasArg("hum_min") || server.hasArg("hum_max")) {
    const float minValue = server.hasArg("hum_min") ? server.arg("hum_min").toFloat() : getHumMin();
    const float maxValue = server.hasArg("hum_max") ? server.arg("hum_max").toFloat() : getHumMax();
    setHumRange(minValue, maxValue);
  }
  if (server.hasArg("hysteresis")) {
    setHysteresis(server.arg("hysteresis").toFloat());
  }
  if (server.hasArg("air_time")) {
    setAirTime(server.arg("air_time").toFloat());
  }
  if (server.hasArg("air_interval")) {
    setAirInterval(server.arg("air_interval").toFloat());
  }
  if (server.hasArg("profile")) {
    setProfile(server.arg("profile"));
  }

  server.send(200, "application/json", "{\"ok\":true}");
}
}

void setupApiServer() {
  server.on("/", HTTP_GET, handleDashboard);
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/control", HTTP_POST, handleControl);
  server.on("/api/control", HTTP_GET, handleControl);
  server.begin();
}

void apiServerLoop(float temp, float hum) {
  latestTemp = temp;
  latestHum = hum;
  server.handleClient();
}

bool isAppConnected() {
  return lastAppContact != 0 && millis() - lastAppContact < 10000;
}