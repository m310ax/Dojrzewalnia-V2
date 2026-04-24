#include <Preferences.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include "config.h"
#include "sensors.h"
#include "wifi_manager.h"

WiFiClientSecure espClient;
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

float tempMin = 0.0F;
float tempMax = 4.0F;
float humMin = 78.0F;
float humMax = 82.0F;
Preferences prefs;
bool prefsReady = false;

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

String scopedTopic(const char* logicalTopic) {
  return String("devices/") + MQTT_DEVICE_ID + "/" + logicalTopic;
}

String logicalTopicFromScoped(const String& topic) {
  const String prefix = String("devices/") + MQTT_DEVICE_ID + "/";
  if (!topic.startsWith(prefix)) {
    return topic;
  }
  return topic.substring(prefix.length());
}

void publishRetained(const char* logicalTopic, const String& value) {
  const String topic = scopedTopic(logicalTopic);
  client.publish(topic.c_str(), value.c_str(), true);
}

void publishDeviceState(float temp, float hum) {
  if (!client.connected()) {
    return;
  }

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

void callback(char* topic, byte* payload, unsigned int length) {
  String msg;

  for (int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  String t = String(topic);
  t = logicalTopicFromScoped(t);

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
  if (client.connect(
          MQTT_CLIENT_ID,
          MQTT_USERNAME,
          MQTT_PASSWORD,
          statusTopic.c_str(),
          0,
          true,
          "offline")) {
    const String commandTopic = scopedTopic("curing/set/#");
    client.subscribe(commandTopic.c_str());
    client.publish(statusTopic.c_str(), "online", true);
  }
}

void setupMQTT() {
  loadRanges();
  espClient.setInsecure();
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