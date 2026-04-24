#include <ArduinoOTA.h>
#include <HTTPClient.h>
#include <Update.h>
#include <WiFi.h>
#include "config.h"

namespace {
volatile bool otaInProgress = false;
unsigned long lastOtaProgressLog = 0;
unsigned long lastHttpOtaCheck = 0;

String readHttpBody(HTTPClient& http) {
  String body = http.getString();
  body.trim();
  return body;
}

bool performHttpFirmwareUpdate() {
  HTTPClient http;
  if (!http.begin(OTA_FIRMWARE_URL)) {
    Serial.println("HTTP OTA begin failed");
    return false;
  }

  const int code = http.GET();
  if (code != HTTP_CODE_OK) {
    Serial.printf("HTTP OTA binary fetch failed: %d\n", code);
    http.end();
    return false;
  }

  const int contentLength = http.getSize();
  WiFiClient* stream = http.getStreamPtr();
  if (contentLength <= 0 || stream == nullptr) {
    Serial.println("HTTP OTA invalid content length");
    http.end();
    return false;
  }

  otaInProgress = true;
  const bool begun = Update.begin(contentLength);
  if (!begun) {
    Serial.println("HTTP OTA Update.begin failed");
    otaInProgress = false;
    http.end();
    return false;
  }

  const size_t written = Update.writeStream(*stream);
  const bool success = written == static_cast<size_t>(contentLength) && Update.end();
  otaInProgress = false;
  http.end();

  if (!success) {
    Serial.printf("HTTP OTA failed, written=%u\n", static_cast<unsigned int>(written));
    return false;
  }

  Serial.println("HTTP OTA complete, restarting");
  ESP.restart();
  return true;
}
}

void setupWiFi() {
  const IPAddress localIp(
      WIFI_STATIC_IP_1,
      WIFI_STATIC_IP_2,
      WIFI_STATIC_IP_3,
      WIFI_STATIC_IP_4);
  const IPAddress gateway(
      WIFI_GATEWAY_1,
      WIFI_GATEWAY_2,
      WIFI_GATEWAY_3,
      WIFI_GATEWAY_4);
  const IPAddress subnet(
      WIFI_SUBNET_1,
      WIFI_SUBNET_2,
      WIFI_SUBNET_3,
      WIFI_SUBNET_4);

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setHostname(OTA_HOSTNAME);

  if (!WiFi.config(localIp, gateway, subnet, gateway, gateway)) {
    Serial.println("WiFi config failed - statyczny IP nieustawiony");
  }

  WiFi.begin(WIFI_SSID, WIFI_PASS);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
  }

  Serial.print("WiFi connected, IP: ");
  Serial.println(WiFi.localIP());
  Serial.print("OTA hostname: ");
  Serial.println(OTA_HOSTNAME);
}

void setupOTA() {
  ArduinoOTA.setHostname(OTA_HOSTNAME);
  ArduinoOTA.setTimeout(5000);

  ArduinoOTA.onStart([]() {
    otaInProgress = true;
    lastOtaProgressLog = 0;
    Serial.println("OTA start");
  });

  ArduinoOTA.onEnd([]() {
    otaInProgress = false;
    Serial.println("OTA done");
  });

  ArduinoOTA.onProgress([](unsigned int progress, unsigned int total) {
    const unsigned int percent = (progress * 100U) / total;
    if (millis() - lastOtaProgressLog >= 500 || percent == 100U) {
      Serial.printf("OTA progress: %u%%\n", percent);
      lastOtaProgressLog = millis();
    }
  });

  ArduinoOTA.onError([](ota_error_t error) {
    otaInProgress = false;
    Serial.printf("OTA error[%u]\n", static_cast<unsigned int>(error));
  });

  ArduinoOTA.begin();
  Serial.println("OTA ready");
}

void handleOTA() {
  ArduinoOTA.handle();
}

void checkHttpOta() {
  if (WiFi.status() != WL_CONNECTED || otaInProgress) {
    return;
  }

  if (millis() - lastHttpOtaCheck < OTA_CHECK_INTERVAL_MS) {
    return;
  }
  lastHttpOtaCheck = millis();

  HTTPClient http;
  if (!http.begin(OTA_VERSION_URL)) {
    Serial.println("HTTP OTA version check begin failed");
    return;
  }

  const int code = http.GET();
  if (code != HTTP_CODE_OK) {
    Serial.printf("HTTP OTA version check failed: %d\n", code);
    http.end();
    return;
  }

  const String remoteVersion = readHttpBody(http);
  http.end();

  if (remoteVersion.isEmpty() || remoteVersion == OTA_FIRMWARE_VERSION) {
    return;
  }

  Serial.printf(
      "HTTP OTA update available: local=%s remote=%s\n",
      OTA_FIRMWARE_VERSION,
      remoteVersion.c_str());
  performHttpFirmwareUpdate();
}

bool isOtaInProgress() {
  return otaInProgress;
}

bool isWiFiConnected() {
  return WiFi.status() == WL_CONNECTED;
}

const char* getLocalIp() {
  static String ip;
  ip = WiFi.localIP().toString();
  return ip.c_str();
}