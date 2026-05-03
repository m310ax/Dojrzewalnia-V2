#include "server_sync.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <WiFi.h>

#include "config.h"
#include "control.h"
#include "mqtt_manager.h"

namespace {
constexpr unsigned long kSendIntervalMs = 10000UL;
constexpr unsigned long kFetchIntervalMs = 60000UL;
constexpr unsigned long kServerTimeoutMs = 120000UL;

float lastHumidity = NAN;
float lastHumRate = 0.0F;
unsigned long lastHumiditySampleMs = 0;
unsigned long lastSendMs = 0;
unsigned long lastFetchMs = 0;
unsigned long lastServerUpdateMs = 0;

String buildAuthHeader() {
  return String("Bearer ") + AI_SERVER_BEARER_TOKEN;
}

float updateHumidityRate(float hum, unsigned long now) {
  if (!isnan(lastHumidity) && lastHumiditySampleMs != 0 && now > lastHumiditySampleMs) {
    const float elapsedSeconds = static_cast<float>(now - lastHumiditySampleMs) / 1000.0F;
    if (elapsedSeconds > 0.0F) {
      lastHumRate = (hum - lastHumidity) / elapsedSeconds;
    }
  }

  lastHumidity = hum;
  lastHumiditySampleMs = now;
  return lastHumRate;
}

bool parseSettingsPayload(const String& payload, float* kpValue, float* targetHum) {
  JsonDocument doc;
  const DeserializationError error = deserializeJson(doc, payload);
  if (error) {
    return false;
  }

  if (!doc["kp"].is<float>() || !doc["targetHum"].is<float>()) {
    return false;
  }

  *kpValue = doc["kp"].as<float>();
  *targetHum = doc["targetHum"].as<float>();
  return true;
}

void applyAiSettings(float kpValue, float targetHum) {
  setCurrentHumidityKp(kpValue);
  setTargetHum(targetHum);
  setHumHysteresis(2.0F);
}

void sendState(float temp, float hum, float humRate) {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  http.begin(String(AI_SERVER_URL) + "/ai/device/state");
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", buildAuthHeader());

  JsonDocument doc;
  doc["deviceId"] = getDeviceId();
  doc["temp"] = temp;
  doc["hum"] = hum;
  doc["humRate"] = humRate;
  doc["kp"] = getCurrentHumidityKp();
  doc["targetHum"] = getTargetHum();

  String body;
  serializeJson(doc, body);

  const int statusCode = http.POST(body);
  if (statusCode == 200) {
    float kpValue = 0.0F;
    float targetHum = 0.0F;
    if (parseSettingsPayload(http.getString(), &kpValue, &targetHum)) {
      applyAiSettings(kpValue, targetHum);
      lastServerUpdateMs = millis();
    }
  }

  http.end();
}

void fetchAISettings() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  http.begin(String(AI_SERVER_URL) + "/ai/device/settings?deviceId=" + getDeviceId());
  http.addHeader("Authorization", buildAuthHeader());

  const int statusCode = http.GET();
  if (statusCode == 200) {
    float kpValue = 0.0F;
    float targetHum = 0.0F;
    if (parseSettingsPayload(http.getString(), &kpValue, &targetHum)) {
      applyAiSettings(kpValue, targetHum);
      lastServerUpdateMs = millis();
    }
  }

  http.end();
}
}

void setupServerSync() {
  lastHumidity = NAN;
  lastHumRate = 0.0F;
  lastHumiditySampleMs = 0;
  lastSendMs = 0;
  lastFetchMs = 0;
  lastServerUpdateMs = millis();
}

void serverSyncLoop(float temp, float hum) {
  const unsigned long now = millis();
  const float humRate = updateHumidityRate(hum, now);

  if (WiFi.status() == WL_CONNECTED) {
    if (now - lastSendMs >= kSendIntervalMs) {
      lastSendMs = now;
      sendState(temp, hum, humRate);
    }

    if (now - lastFetchMs >= kFetchIntervalMs) {
      lastFetchMs = now;
      fetchAISettings();
    }
  }

  if (now - lastServerUpdateMs >= kServerTimeoutMs) {
    restoreDefaultHumidityPid();
  }
}