#include <Arduino.h>
#include <Wire.h>
#include "config.h"
#include "api_server.h"
#include "display_manager.h"
#include "wifi_manager.h"
#include "mqtt_manager.h"
#include "sensors.h"
#include "control.h"

unsigned long lastSend = 0;

void setup() {
  Serial.begin(115200);
  delay(300);

  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(I2C_SPEED);
  Wire.setTimeOut(50);

  initRelays();
  setupSensors();
  initDisplay();
  setupWiFi();
  setupOTA();
  setupMQTT();
  setupApiServer();
}

void loop() {
  handleOTA();
  checkHttpOta();

  if (isOtaInProgress()) {
    delay(1);
    return;
  }

  mqttLoop();

  float temp = readTemp();
  float hum  = readHum();

  controlLogic(temp, hum);
  apiServerLoop(temp, hum);
  updateDisplay(temp, hum);

  if (millis() - lastSend > 2000) {
    lastSend = millis();
    publishData(temp, hum);
  }
}