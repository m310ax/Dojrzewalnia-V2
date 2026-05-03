#include <Arduino.h>
#include <HTTPClient.h>
#include <WebServer.h>

#include "api_server.h"
#include "config.h"
#include "mqtt_manager.h"
#include "sensors.h"
#include "wifi_manager.h"

namespace {
#define MAX_POINTS 100

struct Stage {
  float tempMin;
  float tempMax;
  float humMin;
  float humMax;
  int days;
};

WebServer server(80);
float latestTemp = 0.0F;
float latestHum = 0.0F;
unsigned long lastAppContact = 0;
const char* www_username = "admin";
const char* www_password = "haslo123";
float tempHistory[MAX_POINTS] = {};
float humHistory[MAX_POINTS] = {};
int historyIndex = 0;
int historyCount = 0;
unsigned long lastHistorySample = 0;
unsigned long profileStartTime = 0;
unsigned long lastProfileUpdate = 0;
unsigned long lastAlert = 0;

constexpr unsigned long kHistorySampleIntervalMs = 5000UL;
constexpr unsigned long kProfileUpdateIntervalMs = 3600000UL;
constexpr unsigned long kAlertIntervalMs = 600000UL;

const Stage kSalamiStages[] = {
    {12.0F, 14.0F, 90.0F, 95.0F, 3},
    {12.0F, 14.0F, 85.0F, 88.0F, 5},
    {12.0F, 14.0F, 78.0F, 82.0F, 999},
};

const Stage kSzynkaStages[] = {
    {10.0F, 12.0F, 86.0F, 90.0F, 4},
    {10.0F, 12.0F, 82.0F, 85.0F, 6},
    {10.0F, 12.0F, 76.0F, 80.0F, 999},
};

const uint8_t kPwaIcon[] PROGMEM = {
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x58, 0xB1, 0x62, 0x05,
  0x00, 0x02, 0x72, 0x01, 0x37, 0x38, 0x8E, 0x0E, 0x1F, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

bool relayOn(int pin) {
  return digitalRead(pin) == LOW;
}

String jsonNumber(float value, int decimals = 1) {
  return String(value, decimals);
}

void sendTelegram(const String& message) {
#if defined(TELEGRAM_BOT_TOKEN) && defined(TELEGRAM_CHAT_ID)
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  String encoded = message;
  encoded.replace(" ", "%20");
  encoded.replace("\n", "%0A");
  const String url = String("https://api.telegram.org/bot") + TELEGRAM_BOT_TOKEN + "/sendMessage?chat_id=" + TELEGRAM_CHAT_ID + "&text=" + encoded;
  http.begin(url);
  http.GET();
  http.end();
#else
  Serial.print("Telegram alert: ");
  Serial.println(message);
#endif
}

void checkAlerts(float hum) {
  if (isnan(hum)) {
    return;
  }

  const unsigned long now = millis();
  if (hum < 70.0F && now - lastAlert >= kAlertIntervalMs) {
    sendTelegram("Wilgotnosc za niska");
    lastAlert = now;
  }
}

int getCurrentDay() {
  return static_cast<int>((millis() - profileStartTime) / 86400000UL);
}

const Stage* getStagesForProfile(const String& profileName, size_t* count) {
  if (profileName.equalsIgnoreCase("salami")) {
    *count = sizeof(kSalamiStages) / sizeof(kSalamiStages[0]);
    return kSalamiStages;
  }

  if (profileName.equalsIgnoreCase("szynka")) {
    *count = sizeof(kSzynkaStages) / sizeof(kSzynkaStages[0]);
    return kSzynkaStages;
  }

  *count = 0;
  return nullptr;
}

void applyStage(const Stage& stage) {
  setTempRange(stage.tempMin, stage.tempMax);
  setHumRange(stage.humMin, stage.humMax);
}

void updateProfile(bool force = false) {
  size_t stageCount = 0;
  const Stage* stages = getStagesForProfile(getProfile(), &stageCount);
  if (stages == nullptr || stageCount == 0) {
    return;
  }

  const unsigned long now = millis();
  if (!force && now - lastProfileUpdate < kProfileUpdateIntervalMs) {
    return;
  }

  lastProfileUpdate = now;
  const int day = getCurrentDay();
  int daySum = 0;
  for (size_t index = 0; index < stageCount; ++index) {
    daySum += stages[index].days;
    if (day <= daySum) {
      applyStage(stages[index]);
      return;
    }
  }

  applyStage(stages[stageCount - 1]);
}

bool setProfileSchedule(const String& profileType) {
  size_t stageCount = 0;
  const Stage* stages = getStagesForProfile(profileType, &stageCount);
  if (stages == nullptr || stageCount == 0) {
    return false;
  }

  setProfile(profileType);
  profileStartTime = millis();
  lastProfileUpdate = 0;
  updateProfile(true);
  return true;
}

bool ensureAuthorized(const char* responseType = "application/json") {
  if (WiFi.status() != WL_CONNECTED) {
    if (strcmp(responseType, "text/html; charset=utf-8") == 0) {
      server.send(503, responseType, "<h1>WiFi disconnected</h1>");
    } else {
      server.send(503, responseType, "{\"error\":\"wifi_disconnected\"}");
    }
    return false;
  }

  if (!server.authenticate(www_username, www_password)) {
    server.requestAuthentication();
    return false;
  }

  return true;
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
  <meta name="theme-color" content="#081217">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <link rel="manifest" href="/manifest.json">
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <script>
    if ('serviceWorker' in navigator) {
      window.addEventListener('load', () => {
        navigator.serviceWorker.register('/sw.js').catch(() => {});
      });
    }
  </script>
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
    .chart-card { margin-top: 16px; min-height: 320px; }
    canvas { width: 100%; max-height: 280px; }
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
    <div class="hero" style="margin-top:16px;">
      <h2 style="margin:0 0 10px; font-size:22px;">Profil</h2>
      <div class="actions">
        <button type="button" onclick="setProfileType('salami')">Salami</button>
        <button type="button" onclick="setProfileType('szynka')">Szynka</button>
      </div>
    </div>
    <div class="hero chart-card">
      <h2 style="margin:0 0 10px; font-size:22px;">Historia pomiarow</h2>
      <canvas id="chart"></canvas>
    </div>
  </div>
  <script>
    let chart;

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

    function initChart() {
      const ctx = document.getElementById('chart');
      chart = new Chart(ctx, {
        type: 'line',
        data: {
          labels: [],
          datasets: [
            { label: 'Temp', data: [], borderColor: '#53b3cb', backgroundColor: 'rgba(83,179,203,0.2)', tension: 0.25 },
            { label: 'Hum', data: [], borderColor: '#f2c14e', backgroundColor: 'rgba(242,193,78,0.18)', tension: 0.25 }
          ]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          scales: {
            x: { ticks: { color: '#9eb4c2' }, grid: { color: 'rgba(255,255,255,0.06)' } },
            y: { ticks: { color: '#9eb4c2' }, grid: { color: 'rgba(255,255,255,0.06)' } }
          },
          plugins: {
            legend: { labels: { color: '#eef6fb' } }
          }
        }
      });
    }

    async function updateChart() {
      if (!chart) {
        return;
      }

      try {
        const response = await fetch('/history', { cache: 'no-store' });
        const data = await response.json();
        chart.data.labels = (data.temp || []).map((_, index) => index + 1);
        chart.data.datasets[0].data = data.temp || [];
        chart.data.datasets[1].data = data.hum || [];
        chart.update();
      } catch (error) {
      }
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

    async function setProfileType(profileType) {
      try {
        const response = await fetch(`/profile?type=${encodeURIComponent(profileType)}`, { cache: 'no-store' });
        if (!response.ok) {
          throw new Error('profile failed');
        }
        document.getElementById('statusText').textContent = `Profil ${profileType} aktywny.`;
        refresh();
      } catch (error) {
        document.getElementById('statusText').textContent = 'Nie udało się ustawić profilu.';
      }
    }

    document.getElementById('saveRangesBtn').addEventListener('click', saveRanges);
    document.getElementById('reloadBtn').addEventListener('click', refresh);
    initChart();
    refresh();
    updateChart();
    setInterval(refresh, 2000);
    setInterval(updateChart, 5000);
  </script>
</body>
</html>
)HTML";

String buildHistoryPayload() {
  String payload = "{\"temp\":[";
  for (int index = 0; index < historyCount; ++index) {
    const int actualIndex = (historyIndex - historyCount + index + MAX_POINTS) % MAX_POINTS;
    payload += jsonNumber(tempHistory[actualIndex], 1);
    if (index + 1 < historyCount) {
      payload += ",";
    }
  }
  payload += "],\"hum\":[";
  for (int index = 0; index < historyCount; ++index) {
    const int actualIndex = (historyIndex - historyCount + index + MAX_POINTS) % MAX_POINTS;
    payload += jsonNumber(humHistory[actualIndex], 1);
    if (index + 1 < historyCount) {
      payload += ",";
    }
  }
  payload += "]}";
  return payload;
}

void handleManifest() {
  if (!ensureAuthorized()) {
    return;
  }

  server.send(
      200,
      "application/json",
      "{\"name\":\"Dojrzewalnia\",\"short_name\":\"Dojrzewalnia\",\"start_url\":\"/\",\"display\":\"standalone\",\"background_color\":\"#081217\",\"theme_color\":\"#081217\",\"icons\":[{\"src\":\"/icon.png\",\"sizes\":\"192x192\",\"type\":\"image/png\"}]}"
  );
}

void handleServiceWorker() {
  if (!ensureAuthorized("application/javascript")) {
    return;
  }

  server.send(
      200,
      "application/javascript",
      "self.addEventListener('install', event => { event.waitUntil(caches.open('dojrzewalnia-v1').then(cache => cache.addAll(['/','/manifest.json','/icon.png']))); self.skipWaiting(); });"
      "self.addEventListener('activate', event => { event.waitUntil(self.clients.claim()); });"
      "self.addEventListener('fetch', event => { if (event.request.method !== 'GET') { return; } event.respondWith(caches.match(event.request).then(response => response || fetch(event.request).then(network => { const clone = network.clone(); if (event.request.url.startsWith(self.location.origin)) { caches.open('dojrzewalnia-v1').then(cache => cache.put(event.request, clone)); } return network; }).catch(() => caches.match('/')))); });"
  );
}

void handleIcon() {
  if (!ensureAuthorized("image/png")) {
    return;
  }

  server.send_P(200, "image/png", reinterpret_cast<PGM_P>(kPwaIcon), sizeof(kPwaIcon));
}

void markAppContact() {
  lastAppContact = millis();
}

void handleDashboard() {
  if (!ensureAuthorized("text/html; charset=utf-8")) {
    return;
  }

  server.send(200, "text/html; charset=utf-8", kDashboardHtml);
}

String buildStatusPayload() {
  String payload = "{";
  payload += "\"temp\":" + jsonNumber(latestTemp) + ",";
  payload += "\"hum\":" + jsonNumber(latestHum) + ",";
  payload += "\"humidity\":" + jsonNumber(latestHum) + ",";
  payload += "\"tempMin\":" + jsonNumber(getTempMin()) + ",";
  payload += "\"tempMax\":" + jsonNumber(getTempMax()) + ",";
  payload += "\"humMin\":" + jsonNumber(getHumMin()) + ",";
  payload += "\"humMax\":" + jsonNumber(getHumMax()) + ",";
  payload += "\"targetTemp\":" + jsonNumber(getTargetTemp()) + ",";
  payload += "\"targetHum\":" + jsonNumber(getTargetHum()) + ",";
  payload += "\"tempHysteresis\":" + jsonNumber(getTempHysteresis()) + ",";
  payload += "\"humHysteresis\":" + jsonNumber(getHumHysteresis()) + ",";
  payload += "\"hysteresis\":" + jsonNumber(getHysteresis()) + ",";
  payload += "\"airTime\":" + jsonNumber(getAirTime()) + ",";
  payload += "\"airInterval\":" + jsonNumber(getAirInterval()) + ",";
  payload += "\"profile\":\"" + getProfile() + "\",";
  payload += "\"mode\":\"" + getOperatingMode() + "\",";
  payload += "\"aiEnabled\":" + String(isAiEnabled() ? "true" : "false") + ",";
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
  return payload;
}

void handleStatus() {
  if (!ensureAuthorized()) {
    return;
  }

  markAppContact();

  server.send(200, "application/json", buildStatusPayload());
}

void handleHistory() {
  if (!ensureAuthorized()) {
    return;
  }

  markAppContact();
  server.send(200, "application/json", buildHistoryPayload());
}

void applyControlArgs() {
  markAppContact();

  if (server.hasArg("temp")) {
    setTargetTemp(server.arg("temp").toFloat());
  }
  if (server.hasArg("tempMin")) {
    setTempMin(server.arg("tempMin").toFloat());
  }
  if (server.hasArg("tempMax")) {
    setTempMax(server.arg("tempMax").toFloat());
  }
  if (server.hasArg("temp_min") || server.hasArg("temp_max")) {
    const float minValue = server.hasArg("temp_min") ? server.arg("temp_min").toFloat() : getTempMin();
    const float maxValue = server.hasArg("temp_max") ? server.arg("temp_max").toFloat() : getTempMax();
    setTempRange(minValue, maxValue);
  }
  if (server.hasArg("hum")) {
    setTargetHum(server.arg("hum").toFloat());
  }
  if (server.hasArg("temp_hysteresis")) {
    setTempHysteresis(server.arg("temp_hysteresis").toFloat());
  }
  if (server.hasArg("hum_hysteresis")) {
    setHumHysteresis(server.arg("hum_hysteresis").toFloat());
  }
  if (server.hasArg("humMin")) {
    setHumMin(server.arg("humMin").toFloat());
  }
  if (server.hasArg("humMax")) {
    setHumMax(server.arg("humMax").toFloat());
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
}

void handleControl() {
  if (!ensureAuthorized()) {
    return;
  }

  applyControlArgs();

  server.send(200, "application/json", "{\"ok\":true}");
}

void handleData() {
  handleStatus();
}

void handleSet() {
  if (!ensureAuthorized("text/plain")) {
    return;
  }

  applyControlArgs();
  server.send(200, "text/plain", "OK");
}

void handleProfile() {
  if (!ensureAuthorized("text/plain")) {
    return;
  }

  markAppContact();
  if (!server.hasArg("type")) {
    server.send(400, "text/plain", "Missing profile type");
    return;
  }

  if (!setProfileSchedule(server.arg("type"))) {
    server.send(400, "text/plain", "Unknown profile");
    return;
  }

  server.send(200, "text/plain", "OK");
}

void handleOtaTrigger() {
  if (!ensureAuthorized()) {
    return;
  }

  markAppContact();
  requestHttpOtaCheck();

  String payload = "{";
  payload += "\"ok\":true,";
  payload += "\"queued\":true,";
  payload += "\"otaInProgress\":" + String(isOtaInProgress() ? "true" : "false") + ",";
  payload += "\"otaCheckPending\":" + String(isHttpOtaCheckPending() ? "true" : "false") + ",";
  payload += "\"currentVersion\":\"" + String(OTA_FIRMWARE_VERSION) + "\"";
  payload += "}";
  server.send(200, "application/json", payload);
}
}

void setupApiServer() {
  server.on("/", HTTP_GET, handleDashboard);
  server.on("/data", HTTP_GET, handleData);
  server.on("/set", HTTP_GET, handleSet);
  server.on("/history", HTTP_GET, handleHistory);
  server.on("/manifest.json", HTTP_GET, handleManifest);
  server.on("/sw.js", HTTP_GET, handleServiceWorker);
  server.on("/icon.png", HTTP_GET, handleIcon);
  server.on("/profile", HTTP_GET, handleProfile);
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/ota", HTTP_POST, handleOtaTrigger);
  server.on("/api/ota", HTTP_GET, handleOtaTrigger);
  server.on("/api/control", HTTP_POST, handleControl);
  server.on("/api/control", HTTP_GET, handleControl);
  server.begin();
}

void addToHistory(float temp, float hum) {
  const unsigned long now = millis();
  if (lastHistorySample != 0 && now - lastHistorySample < kHistorySampleIntervalMs) {
    return;
  }

  lastHistorySample = now;
  tempHistory[historyIndex] = temp;
  humHistory[historyIndex] = hum;
  historyIndex = (historyIndex + 1) % MAX_POINTS;
  if (historyCount < MAX_POINTS) {
    ++historyCount;
  }
}

void apiServerLoop(float temp, float hum) {
  latestTemp = temp;
  latestHum = hum;
  updateProfile();
  checkAlerts(hum);
  server.handleClient();
}

bool isAppConnected() {
  return lastAppContact != 0 && millis() - lastAppContact < 10000;
}