#include <Preferences.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <esp_system.h>
#include "config.h"
#include "sensors.h"
#include "wifi_manager.h"

WiFiClient espClient;
PubSubClient client(espClient);

float getTargetTemp();
float getTargetHum();
float getHysteresis();
float getAirTime();
float getAirInterval();
String getProfile();

namespace {
constexpr float kTempLowerLimit = 0.0F;
constexpr float kTempUpperLimit = 25.0F;
constexpr float kHumLowerLimit = 50.0F;
constexpr float kHumUpperLimit = 100.0F;
constexpr const char* kPrefsNamespace = "curing";
constexpr const char* kDeviceIdKey = "deviceId";
constexpr const char* kDeviceIdPrefix = "ESP-";

float tempMin = 0.0F;
float tempMax = 4.0F;
float humMin = 78.0F;
float humMax = 82.0F;
Preferences prefs;
bool prefsReady = false;
bool coolOverrideEnabled = false;
bool coolOverrideState = false;
bool fanOverrideEnabled = false;
bool fanOverrideState = true;
String deviceId = MQTT_DEVICE_ID;

String generateDeviceId() {
  static const char charset[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  String generatedId = kDeviceIdPrefix;
  for (int index = 0; index < 6; ++index) {
    generatedId += charset[esp_random() % (sizeof(charset) - 1)];
  }
  return generatedId;
}

void normalizeTempRange(float* minValue, float* maxValue) {
  *minValue = constrain(*minValue, kTempLowerLimit, kTempUpperLimit);
  *maxValue = constrain(*maxValue, kTempLowerLimit, kTempUpperLimit);
  if (*minValue > *maxValue) {
    const float swapValue = *minValue;
    *minValue = *maxValue;
    *maxValue = swapValue;
  }
}

void normalizeHumRange(float* minValue, float* maxValue) {
  *minValue = constrain(*minValue, kHumLowerLimit, kHumUpperLimit);
  *maxValue = constrain(*maxValue, kHumLowerLimit, kHumUpperLimit);
  if (*minValue > *maxValue) {
    const float swapValue = *minValue;
    *minValue = *maxValue;
    *maxValue = swapValue;
  }
}

void ensurePreferences() {
  if (!prefsReady) {
    prefsReady = prefs.begin(kPrefsNamespace, false);
  }
}

void saveRanges() {
  ensurePreferences();
  if (!prefsReady) {
    return;
  }

  prefs.putFloat("tempMin", tempMin);
  prefs.putFloat("tempMax", tempMax);
  prefs.putFloat("humMin", humMin);
  prefs.putFloat("humMax", humMax);
}

void loadRanges() {
  ensurePreferences();
  if (!prefsReady) {
    return;
  }

  float storedTempMin = prefs.getFloat("tempMin", tempMin);
  float storedTempMax = prefs.getFloat("tempMax", tempMax);
  float storedHumMin = prefs.getFloat("humMin", humMin);
  float storedHumMax = prefs.getFloat("humMax", humMax);

  normalizeTempRange(&storedTempMin, &storedTempMax);
  normalizeHumRange(&storedHumMin, &storedHumMax);

  tempMin = storedTempMin;
  tempMax = storedTempMax;
  humMin = storedHumMin;
  humMax = storedHumMax;
}

void loadDeviceId() {
  ensurePreferences();
  if (!prefsReady) {
    deviceId = MQTT_DEVICE_ID;
    return;
  }

  const String storedDeviceId = prefs.getString(kDeviceIdKey, "");
  if (storedDeviceId.length() > 0) {
    deviceId = storedDeviceId;
    return;
  }

  deviceId = generateDeviceId();
  prefs.putString(kDeviceIdKey, deviceId);
}

String scopedTopic(const char* logicalTopic) {
  return String("devices/") + deviceId + "/" + logicalTopic;
}

String logicalTopicFromScoped(const String& topic) {
  const String prefix = String("devices/") + deviceId + "/";
  if (!topic.startsWith(prefix)) {
    return topic;
  }
  return topic.substring(prefix.length());
}

void publishRetained(const char* logicalTopic, const String& value) {
  const String topic = scopedTopic(logicalTopic);
  client.publish(topic.c_str(), value.c_str(), true);
}

bool parseSwitchOverrideMessage(const String& rawMessage, bool* enabled, bool* state) {
  String msg = rawMessage;
  msg.trim();
  msg.toLowerCase();

  if (msg == "auto") {
    *enabled = false;
    *state = true;
    return true;
  }

  int colonIndex = msg.indexOf(':');
  if (msg.startsWith("{") && colonIndex >= 0) {
    int endIndex = msg.indexOf('}', colonIndex + 1);
    if (endIndex < 0) {
      endIndex = msg.length();
    }
    msg = msg.substring(colonIndex + 1, endIndex);
    msg.replace("\"", "");
    msg.trim();
  }

  if (msg == "1" || msg == "true" || msg == "on" || msg == "high") {
    *enabled = true;
    *state = true;
    return true;
  }

  if (msg == "0" || msg == "false" || msg == "off" || msg == "low") {
    *enabled = true;
    *state = false;
    return true;
  }

  return false;
}

void publishJsonSnapshot(float temp, float hum) {
  char payload[96];
  snprintf(
      payload,
      sizeof(payload),
      "{\"temp\": %.2f, \"hum\": %.2f}",
      temp,
      hum);
  publishRetained("data", String(payload));
}

void publishAvailability() {
  if (!client.connected()) {
    return;
  }

  char payload[160];
  snprintf(
      payload,
      sizeof(payload),
      "{\"id\":\"%s\",\"ip\":\"%s\",\"rssi\":%d}",
      deviceId.c_str(),
      getLocalIp(),
      WiFi.RSSI());
  client.publish("devices/available", payload);
}

void publishDeviceState(float temp, float hum) {
  if (!client.connected()) {
    return;
  }

  publishAvailability();
  publishJsonSnapshot(temp, hum);
  publishRetained("curing/status", "online");
  publishRetained("curing/temp", String(temp, 1));
  publishRetained("curing/humidity", String(hum, 1));
  publishRetained("curing/set/temp_min", String(tempMin, 1));
  publishRetained("curing/set/temp_max", String(tempMax, 1));
  publishRetained("curing/set/hum_min", String(humMin, 0));
  publishRetained("curing/set/hum_max", String(humMax, 0));
  publishRetained("curing/set/temp", String(getTargetTemp(), 1));
  publishRetained("curing/set/hum", String(getTargetHum(), 1));
  publishRetained("curing/set/hysteresis", String(getHysteresis(), 1));
  publishRetained("curing/set/air_time", String(getAirTime(), 1));
  publishRetained("curing/set/air_interval", String(getAirInterval(), 1));
  publishRetained("curing/set/profile", getProfile());
  publishRetained("curing/mode", getProfile());
  publishRetained("curing/device/id", deviceId);
  publishRetained("curing/device/ip", String(getLocalIp()));
  publishRetained("curing/device/sensor", isSensorConnected() ? "true" : "false");
  publishRetained("curing/device/wifi", isWiFiConnected() ? "true" : "false");
}
}

float airTime = 10.0;
float airInterval = 10.0;
String profile = "AUTO";
unsigned long lastReconnectAttempt = 0;

void setTempRange(float minValue, float maxValue) {
  normalizeTempRange(&minValue, &maxValue);
  tempMin = minValue;
  tempMax = maxValue;
  saveRanges();
}

void setHumRange(float minValue, float maxValue) {
  normalizeHumRange(&minValue, &maxValue);
  humMin = minValue;
  humMax = maxValue;
  saveRanges();
}

void setTempMin(float value) {
  setTempRange(value, tempMax);
}

void setTempMax(float value) {
  setTempRange(tempMin, value);
}

void setHumMin(float value) {
  setHumRange(value, humMax);
}

void setHumMax(float value) {
  setHumRange(humMin, value);
}

float getTempMin() {
  return tempMin;
}

float getTempMax() {
  return tempMax;
}

float getHumMin() {
  return humMin;
}

float getHumMax() {
  return humMax;
}

void setTargetTemp(float value) {
  const float halfSpan = (tempMax - tempMin) * 0.5F;
  setTempRange(value - halfSpan, value + halfSpan);
}

void setTargetHum(float value) {
  const float halfSpan = (humMax - humMin) * 0.5F;
  setHumRange(value - halfSpan, value + halfSpan);
}

void setHysteresis(float value) {
  const float safeValue = max(0.0F, value);
  const float tempCenter = getTargetTemp();
  const float humCenter = getTargetHum();
  setTempRange(tempCenter - safeValue, tempCenter + safeValue);
  setHumRange(humCenter - safeValue, humCenter + safeValue);
}

void setAirTime(float value) {
  airTime = value;
}

void setAirInterval(float value) {
  airInterval = value;
}

void setProfile(const String& value) {
  profile = value;
}

void setCoolOverride(bool enabled, bool on) {
  coolOverrideEnabled = enabled;
  coolOverrideState = on;
}

bool isCoolOverrideEnabled() {
  return coolOverrideEnabled;
}

bool getCoolOverrideState() {
  return coolOverrideState;
}

void setFanOverride(bool enabled, bool on) {
  fanOverrideEnabled = enabled;
  fanOverrideState = on;
}

bool isFanOverrideEnabled() {
  return fanOverrideEnabled;
}

bool getFanOverrideState() {
  return fanOverrideState;
}

String getDeviceId() {
  return deviceId;
}

void callback(char* topic, byte* payload, unsigned int length) {
  String msg;

  for (int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  String t = String(topic);
  t = logicalTopicFromScoped(t);

  if (t == "control/cool") {
    bool enabled = false;
    bool state = false;
    if (parseSwitchOverrideMessage(msg, &enabled, &state)) {
      setCoolOverride(enabled, state);
    }
    return;
  }

  if (t == "control/fan") {
    bool enabled = false;
    bool state = true;
    if (parseSwitchOverrideMessage(msg, &enabled, &state)) {
      setFanOverride(enabled, state);
    }
    return;
  }

  if (t == "curing/set/temp") setTargetTemp(msg.toFloat());
  if (t == "curing/set/hum") setTargetHum(msg.toFloat());
  if (t == "curing/set/temp_min") setTempMin(msg.toFloat());
  if (t == "curing/set/temp_max") setTempMax(msg.toFloat());
  if (t == "curing/set/hum_min") setHumMin(msg.toFloat());
  if (t == "curing/set/hum_max") setHumMax(msg.toFloat());
  if (t == "curing/set/hysteresis") setHysteresis(msg.toFloat());
  if (t == "curing/set/air_time") setAirTime(msg.toFloat());
  if (t == "curing/set/air_interval") setAirInterval(msg.toFloat());
  if (t == "curing/set/profile") setProfile(msg);
}

void reconnect() {
  if (client.connected()) {
    return;
  }

  if (millis() - lastReconnectAttempt < 5000) {
    return;
  }

  lastReconnectAttempt = millis();
  const String statusTopic = scopedTopic("curing/status");
    const String clientId = String(MQTT_CLIENT_ID) + "-" + deviceId;
  if (client.connect(
      clientId.c_str(),
          MQTT_USERNAME,
          MQTT_PASSWORD,
          statusTopic.c_str(),
          0,
          true,
          "offline")) {
    const String commandTopic = scopedTopic("curing/set/#");
    const String controlTopic = scopedTopic("control/#");
    client.subscribe(commandTopic.c_str());
    client.subscribe(controlTopic.c_str());
    client.publish(statusTopic.c_str(), "online", true);
  }
}

void setupMQTT() {
  loadRanges();
  loadDeviceId();
  client.setServer(MQTT_SERVER, MQTT_PORT);
  client.setCallback(callback);
}

void mqttLoop() {
  if (!client.connected()) reconnect();
  client.loop();
}

void publishData(float temp, float hum) {
  publishDeviceState(temp, hum);
}

float getTargetTemp() {
  return (tempMin + tempMax) * 0.5F;
}

float getTargetHum() {
  return (humMin + humMax) * 0.5F;
}

float getHysteresis() {
  return (tempMax - tempMin) * 0.5F;
}

float getAirTime() {
  return airTime;
}

float getAirInterval() {
  return airInterval;
}

String getProfile() {
  return profile;
}

bool isMqttConnected() {
  return client.connected();
}