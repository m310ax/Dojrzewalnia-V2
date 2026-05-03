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
float getTempHysteresis();
float getHumHysteresis();
float getHysteresis();
float getAirTime();
float getAirInterval();
String getProfile();
String getOperatingMode();
bool isAiEnabled();

namespace {
constexpr float kTempLowerLimit = 0.0F;
constexpr float kTempUpperLimit = 25.0F;
constexpr float kHumLowerLimit = 40.0F;
constexpr float kHumUpperLimit = 100.0F;
constexpr const char* kPrefsNamespace = "curing";
constexpr const char* kDeviceIdKey = "deviceId";
constexpr const char* kDeviceIdPrefix = "ESP-";

float tempMin = 0.0F;
float tempMax = 4.0F;
float humMin = 78.0F;
float humMax = 82.0F;
float targetTemp = 2.0F;
float targetHum = 80.0F;
float tempHysteresis = 2.0F;
float humHysteresis = 2.0F;
Preferences prefs;
bool prefsReady = false;
bool coolOverrideEnabled = false;
bool coolOverrideState = false;
bool humOverrideEnabled = false;
bool humOverrideState = false;
bool fanOverrideEnabled = false;
bool fanOverrideState = true;
bool aiEnabled = false;
bool suppressRetainedSettingsPublish = false;
String deviceId = MQTT_DEVICE_ID;

void publishRetained(const char* logicalTopic, const String& value);

String normalizeModeValue(const String& rawValue) {
  String normalized = rawValue;
  normalized.trim();
  normalized.toLowerCase();

  if (normalized == "ai") {
    return "ai";
  }

  if (normalized == "auto") {
    return "auto";
  }

  return "manual";
}

void clearOverrides() {
  coolOverrideEnabled = false;
  coolOverrideState = false;
  humOverrideEnabled = false;
  humOverrideState = false;
  fanOverrideEnabled = false;
  fanOverrideState = true;
}

bool parseBooleanMessage(const String& rawMessage, bool* value) {
  String msg = rawMessage;
  msg.trim();
  msg.toLowerCase();

  if (msg == "1" || msg == "true" || msg == "on" || msg == "high" || msg == "yes") {
    *value = true;
    return true;
  }

  if (msg == "0" || msg == "false" || msg == "off" || msg == "low" || msg == "no") {
    *value = false;
    return true;
  }

  return false;
}

bool parseFloatMessage(const String& rawMessage, float* value) {
  String msg = rawMessage;
  msg.trim();
  if (msg.length() == 0) {
    return false;
  }

  char* endPtr = nullptr;
  const float parsedValue = strtof(msg.c_str(), &endPtr);
  if (endPtr == msg.c_str()) {
    return false;
  }

  while (endPtr != nullptr && *endPtr != '\0') {
    if (!isspace(static_cast<unsigned char>(*endPtr))) {
      return false;
    }
    ++endPtr;
  }

  *value = parsedValue;
  return true;
}

void publishControlState() {
  if (!client.connected()) {
    return;
  }

  publishRetained("curing/mode", getOperatingMode());
  publishRetained("control/ai", isAiEnabled() ? "true" : "false");
}

void publishRetainedSettingsState() {
  if (!client.connected()) {
    return;
  }

  // Clear legacy retained topics so reconnects cannot reapply stale min/max values.
  publishRetained("curing/set/temp_min", "");
  publishRetained("curing/set/temp_max", "");
  publishRetained("curing/set/hum_min", "");
  publishRetained("curing/set/hum_max", "");
  publishRetained("curing/set/hysteresis", "");
  publishRetained("curing/set/temp", String(getTargetTemp(), 1));
  publishRetained("curing/set/hum", String(getTargetHum(), 1));
  publishRetained("curing/set/temp_hysteresis", String(getTempHysteresis(), 1));
  publishRetained("curing/set/hum_hysteresis", String(getHumHysteresis(), 1));
  publishRetained("curing/set/air_time", String(getAirTime(), 1));
  publishRetained("curing/set/air_interval", String(getAirInterval(), 1));
  publishRetained("curing/set/profile", getProfile());
}

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

void syncTempRangeFromTarget() {
  targetTemp = constrain(targetTemp, kTempLowerLimit, kTempUpperLimit);
  tempHysteresis = max(tempHysteresis, 0.0F);
  tempMin = targetTemp;
  tempMax = constrain(targetTemp + tempHysteresis, targetTemp, kTempUpperLimit);
  tempHysteresis = tempMax - targetTemp;
}

void syncHumRangeFromTarget() {
  targetHum = constrain(targetHum, kHumLowerLimit, kHumUpperLimit);
  humHysteresis = max(humHysteresis, 0.0F);
  humMax = targetHum;
  humMin = constrain(targetHum - humHysteresis, kHumLowerLimit, targetHum);
  humHysteresis = targetHum - humMin;
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
  prefs.putFloat("targetTemp", targetTemp);
  prefs.putFloat("targetHum", targetHum);
  prefs.putFloat("tempHyst", tempHysteresis);
  prefs.putFloat("humHyst", humHysteresis);
  if (!suppressRetainedSettingsPublish) {
    publishRetainedSettingsState();
  }
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
  targetTemp = constrain(prefs.getFloat("targetTemp", tempMin), kTempLowerLimit, kTempUpperLimit);
  targetHum = constrain(prefs.getFloat("targetHum", humMax), kHumLowerLimit, kHumUpperLimit);
  tempHysteresis = prefs.getFloat("tempHyst", max(tempMax - targetTemp, 0.0F));
  humHysteresis = prefs.getFloat("humHyst", max(targetHum - humMin, 0.0F));
  syncTempRangeFromTarget();
  syncHumRangeFromTarget();
}

void loadDeviceId() {
  ensurePreferences();
  const String configuredDeviceId = String(MQTT_DEVICE_ID);
  if (configuredDeviceId.length() > 0) {
    deviceId = configuredDeviceId;
    if (prefsReady) {
      prefs.putString(kDeviceIdKey, deviceId);
    }
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
  char payload[128];
  snprintf(
      payload,
      sizeof(payload),
      "{\"device_id\":\"%s\",\"temp\":%.2f,\"hum\":%.2f}",
      deviceId.c_str(),
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
  publishRetainedSettingsState();
  publishControlState();
  publishRetained("curing/device/id", deviceId);
  publishRetained("curing/device/ip", String(getLocalIp()));
  publishRetained("curing/device/sensor", isSensorConnected() ? "true" : "false");
  publishRetained("curing/device/wifi", isWiFiConnected() ? "true" : "false");
}
}

float airTime = 10.0;
float airInterval = 10.0;
String profile = "AUTO";
String operatingMode = "manual";
unsigned long lastReconnectAttempt = 0;

void setTempRange(float minValue, float maxValue) {
  normalizeTempRange(&minValue, &maxValue);
  targetTemp = minValue;
  tempHysteresis = max(maxValue - minValue, 0.0F);
  syncTempRangeFromTarget();
  saveRanges();
}

void setHumRange(float minValue, float maxValue) {
  normalizeHumRange(&minValue, &maxValue);
  targetHum = maxValue;
  humHysteresis = max(maxValue - minValue, 0.0F);
  syncHumRangeFromTarget();
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
  targetTemp = constrain(value, kTempLowerLimit, kTempUpperLimit);
  syncTempRangeFromTarget();
  saveRanges();
}

void setTargetHum(float value) {
  targetHum = constrain(value, kHumLowerLimit, kHumUpperLimit);
  syncHumRangeFromTarget();
  saveRanges();
}

void setTempHysteresis(float value) {
  tempHysteresis = max(value, 0.0F);
  syncTempRangeFromTarget();
  saveRanges();
}

void setHumHysteresis(float value) {
  humHysteresis = max(value, 0.0F);
  syncHumRangeFromTarget();
  saveRanges();
}

void setHysteresis(float value) {
  const float safeValue = max(0.0F, value);
  tempHysteresis = safeValue;
  humHysteresis = safeValue;
  syncTempRangeFromTarget();
  syncHumRangeFromTarget();
  saveRanges();
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

void setOperatingMode(const String& value) {
  operatingMode = normalizeModeValue(value);
  aiEnabled = operatingMode == "ai";
  clearOverrides();
  publishControlState();
}

void setAiEnabled(bool enabled) {
  aiEnabled = enabled;
  if (enabled) {
    operatingMode = "ai";
  } else if (operatingMode == "ai") {
    operatingMode = "manual";
  }
  clearOverrides();
  publishControlState();
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

void setHumOverride(bool enabled, bool on) {
  humOverrideEnabled = enabled;
  humOverrideState = on;
}

bool isHumOverrideEnabled() {
  return humOverrideEnabled;
}

bool getHumOverrideState() {
  return humOverrideState;
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

  if (t == "control/heater") {
    bool enabled = false;
    bool state = false;
    if (parseSwitchOverrideMessage(msg, &enabled, &state)) {
      setCoolOverride(enabled, state);
    }
    return;
  }

  if (t == "control/hum" || t == "control/humifier" || t == "control/humidifier") {
    bool enabled = false;
    bool state = false;
    if (parseSwitchOverrideMessage(msg, &enabled, &state)) {
      setHumOverride(enabled, state);
    }
    return;
  }

  if (t == "control/dehumidifier") {
    bool enabled = false;
    bool state = false;
    if (parseSwitchOverrideMessage(msg, &enabled, &state)) {
      setFanOverride(enabled, state);
    }
    return;
  }

  if (t == "control/mode") {
    setOperatingMode(msg);
    return;
  }

  if (t == "control/ai") {
    bool enabled = false;
    if (parseBooleanMessage(msg, &enabled)) {
      setAiEnabled(enabled);
    }
    return;
  }

  if (t.startsWith("curing/set/")) {
    msg.trim();
    if (msg.length() == 0) {
      return;
    }

    Serial.printf("MQTT setting received: %s = %s\n", t.c_str(), msg.c_str());

    suppressRetainedSettingsPublish = true;

    float numericValue = 0.0F;
    const bool hasNumericValue = parseFloatMessage(msg, &numericValue);

    if (t == "curing/set/temp") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setTargetTemp(numericValue);
      }
    } else if (t == "curing/set/hum") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setTargetHum(numericValue);
      }
    } else if (t == "curing/set/temp_hysteresis") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setTempHysteresis(numericValue);
      }
    } else if (t == "curing/set/hum_hysteresis") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setHumHysteresis(numericValue);
      }
    } else if (t == "curing/set/air_time") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setAirTime(numericValue);
      }
    } else if (t == "curing/set/air_interval") {
      if (!hasNumericValue) {
        Serial.printf("MQTT setting ignored, invalid float for %s: %s\n", t.c_str(), msg.c_str());
      } else {
        setAirInterval(numericValue);
      }
    } else if (t == "curing/set/profile") {
      setProfile(msg);
    }

    suppressRetainedSettingsPublish = false;
    return;
  }
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
    client.publish(statusTopic.c_str(), "online", true);
    publishRetainedSettingsState();
    publishControlState();
    const String commandTopic = scopedTopic("curing/set/#");
    const String controlTopic = scopedTopic("control/#");
    client.subscribe(commandTopic.c_str());
    client.subscribe(controlTopic.c_str());
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
  return targetTemp;
}

float getTargetHum() {
  return targetHum;
}

float getTempHysteresis() {
  return tempHysteresis;
}

float getHumHysteresis() {
  return humHysteresis;
}

float getHysteresis() {
  return tempHysteresis;
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

String getOperatingMode() {
  return operatingMode;
}

bool isAiEnabled() {
  return aiEnabled;
}

bool isMqttConnected() {
  return client.connected();
}