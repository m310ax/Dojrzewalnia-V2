#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoOTA.h>
#include <Wire.h>
#include <Adafruit_SHT4x.h>

namespace {
constexpr char kWifiSsid[] = "WIFI";
constexpr char kWifiPassword[] = "PASS";
constexpr char kMqttServer[] = "yasmin345.mikrus.xyz";
constexpr int kMqttPort = 30345;
constexpr char kMqttUser[] = "curing_user";
constexpr char kMqttPassword[] = "mocne";
constexpr uint8_t kRelayCool = 5;
constexpr uint8_t kRelayHum = 18;
constexpr uint8_t kI2cSda = 21;
constexpr uint8_t kI2cScl = 22;
constexpr unsigned long kPublishIntervalMs = 2000UL;
}

WiFiClient wifiClient;
PubSubClient client(wifiClient);
Adafruit_SHT4x sht4;

String deviceId;
unsigned long lastPublishAt = 0;
bool cooling = false;
bool humidifier = false;

bool extractJsonBoolField(const String& payload, const char* fieldName, bool* value) {
  const String field = String("\"") + fieldName + "\":";
  const int fieldIndex = payload.indexOf(field);
  if (fieldIndex < 0) {
    return false;
  }

  int valueIndex = fieldIndex + field.length();
  while (valueIndex < payload.length() && isspace(static_cast<unsigned char>(payload[valueIndex]))) {
    ++valueIndex;
  }

  if (payload.startsWith("true", valueIndex)) {
    *value = true;
    return true;
  }

  if (payload.startsWith("false", valueIndex)) {
    *value = false;
    return true;
  }

  return false;
}

bool extractJsonStringField(const String& payload, const char* fieldName, String* value) {
  const String field = String("\"") + fieldName + "\":";
  const int fieldIndex = payload.indexOf(field);
  if (fieldIndex < 0) {
    return false;
  }

  const int startQuote = payload.indexOf('"', fieldIndex + field.length());
  if (startQuote < 0) {
    return false;
  }

  const int endQuote = payload.indexOf('"', startQuote + 1);
  if (endQuote < 0) {
    return false;
  }

  *value = payload.substring(startQuote + 1, endQuote);
  return true;
}

void applyOutputs() {
  digitalWrite(kRelayCool, cooling ? HIGH : LOW);
  digitalWrite(kRelayHum, humidifier ? HIGH : LOW);
}

void handleControlPayload(const String& payload) {
  Serial.println("CMD: " + payload);

  String mode;
  if (extractJsonStringField(payload, "mode", &mode)) {
    mode.toLowerCase();
    if (mode == "auto") {
      cooling = false;
      humidifier = false;
    }
  }

  bool nextValue = false;
  if (extractJsonBoolField(payload, "cooling", &nextValue)) {
    cooling = nextValue;
  }

  if (extractJsonBoolField(payload, "humidifier", &nextValue)) {
    humidifier = nextValue;
  }

  applyOutputs();
}

void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += static_cast<char>(payload[i]);
  }

  const String fullTopic(topic);
  const String controlTopic = String("devices/") + deviceId + "/control";
  if (fullTopic != controlTopic) {
    return;
  }

  handleControlPayload(message);
}

void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(kWifiSsid, kWifiPassword);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
  }
}

void publishState(float temperature, float humidity) {
  const String baseTopic = String("devices/") + deviceId + "/";
  const String payload =
      String("{\"device_id\":\"") + deviceId +
      "\",\"temp\":" + String(temperature, 2) +
      ",\"hum\":" + String(humidity, 2) + "}";

  client.publish((baseTopic + "data").c_str(), payload.c_str(), true);
  client.publish((baseTopic + "curing/temp").c_str(), String(temperature, 2).c_str(), true);
  client.publish((baseTopic + "curing/humidity").c_str(), String(humidity, 2).c_str(), true);
  client.publish((baseTopic + "curing/status").c_str(), "online", true);
  client.publish((baseTopic + "curing/device/wifi").c_str(), "true", true);
}

void reconnect() {
  while (!client.connected()) {
    if (client.connect(deviceId.c_str(), kMqttUser, kMqttPassword)) {
      client.subscribe((String("devices/") + deviceId + "/control").c_str());
      client.publish((String("devices/") + deviceId + "/curing/status").c_str(), "online", true);
    } else {
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(kRelayCool, OUTPUT);
  pinMode(kRelayHum, OUTPUT);
  applyOutputs();

  Wire.begin(kI2cSda, kI2cScl);
  sht4.begin();

  randomSeed(static_cast<uint32_t>(esp_random()));
  deviceId = "ESP-" + String(random(100000, 999999));

  connectWifi();

  ArduinoOTA.setHostname(deviceId.c_str());
  ArduinoOTA.begin();

  client.setServer(kMqttServer, kMqttPort);
  client.setCallback(callback);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
  }

  if (!client.connected()) {
    reconnect();
  }

  client.loop();
  ArduinoOTA.handle();

  if (millis() - lastPublishAt < kPublishIntervalMs) {
    delay(10);
    return;
  }

  sensors_event_t humidityEvent;
  sensors_event_t temperatureEvent;
  sht4.getEvent(&humidityEvent, &temperatureEvent);

  lastPublishAt = millis();
  publishState(temperatureEvent.temperature, humidityEvent.relative_humidity);
}