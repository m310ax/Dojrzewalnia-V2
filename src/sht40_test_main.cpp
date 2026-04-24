#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_SHT4x.h>

#include "config.h"

namespace {
Adafruit_SHT4x sht4;
bool sensorReady = false;
unsigned long lastRead = 0;
constexpr int TEST_I2C_SDA = I2C_SDA;
constexpr int TEST_I2C_SCL = I2C_SCL;

void reinitWire() {
  Wire.end();
  delay(5);
  Wire.begin(TEST_I2C_SDA, TEST_I2C_SCL);
  Wire.setClock(I2C_SPEED);
  Wire.setTimeOut(50);
}

void printLineStates(const char* label) {
  pinMode(TEST_I2C_SDA, INPUT_PULLUP);
  pinMode(TEST_I2C_SCL, INPUT_PULLUP);
  delay(1);
  Serial.printf(
      "%s SDA=%d SCL=%d\n",
      label,
      digitalRead(TEST_I2C_SDA),
      digitalRead(TEST_I2C_SCL));
}

bool isI2cBusIdle() {
  pinMode(TEST_I2C_SDA, INPUT_PULLUP);
  pinMode(TEST_I2C_SCL, INPUT_PULLUP);
  delay(1);
  return digitalRead(TEST_I2C_SDA) == HIGH && digitalRead(TEST_I2C_SCL) == HIGH;
}

void recoverI2cBus() {
  pinMode(TEST_I2C_SDA, INPUT_PULLUP);
  pinMode(TEST_I2C_SCL, INPUT_PULLUP);
  delay(2);

  if (digitalRead(TEST_I2C_SDA) == LOW) {
    pinMode(TEST_I2C_SCL, OUTPUT_OPEN_DRAIN);
    digitalWrite(TEST_I2C_SCL, HIGH);

    for (uint8_t pulse = 0; pulse < 9 && digitalRead(TEST_I2C_SDA) == LOW; pulse++) {
      digitalWrite(TEST_I2C_SCL, LOW);
      delayMicroseconds(10);
      digitalWrite(TEST_I2C_SCL, HIGH);
      delayMicroseconds(10);
    }

    pinMode(TEST_I2C_SDA, OUTPUT_OPEN_DRAIN);
    digitalWrite(TEST_I2C_SDA, LOW);
    delayMicroseconds(10);
    digitalWrite(TEST_I2C_SCL, HIGH);
    delayMicroseconds(10);
    digitalWrite(TEST_I2C_SDA, HIGH);
  }

  reinitWire();
}

void scanI2cBus() {
  bool foundDevice = false;

  Serial.println("I2C scan start");

  if (!isI2cBusIdle()) {
    Serial.println("I2C scan aborted: SDA/SCL nie sa w stanie HIGH");
    return;
  }

  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    const uint8_t error = Wire.endTransmission();
    if (error == 0) {
      foundDevice = true;
      Serial.printf("I2C device at 0x%02X\n", address);
    } else if (error == 4) {
      Serial.printf("I2C unknown error at 0x%02X\n", address);
    }
  }

  if (!foundDevice) {
    Serial.println("I2C scan result: brak urzadzen");
  }
  Serial.println("I2C scan done");
}

bool initSht4x() {
  if (!sht4.begin(&Wire)) {
    Serial.println("SHT40 begin failed");
    return false;
  }

  sht4.setPrecision(SHT4X_HIGH_PRECISION);
  sht4.setHeater(SHT4X_NO_HEATER);
  Serial.println("SHT40 ready");
  return true;
}

void readSht4x() {
  sensors_event_t humidityEvent;
  sensors_event_t temperatureEvent;

  if (!sht4.getEvent(&humidityEvent, &temperatureEvent)) {
    Serial.println("SHT40 read failed");
    sensorReady = false;
    return;
  }

  Serial.printf(
      "SHT40 temp=%.2fC hum=%.2f%%\n",
      temperatureEvent.temperature,
      humidityEvent.relative_humidity);
}
}

void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println();
  Serial.println("=== SHT40 SOLO TEST ===");
  Serial.printf("SDA=%d SCL=%d I2C=%ld\n", TEST_I2C_SDA, TEST_I2C_SCL, I2C_SPEED);

  printLineStates("Before Wire.begin");

  Wire.begin(TEST_I2C_SDA, TEST_I2C_SCL);
  Wire.setClock(I2C_SPEED);
  Wire.setTimeOut(50);
  delay(100);

  recoverI2cBus();

  printLineStates("After Wire.begin");

  scanI2cBus();
  sensorReady = initSht4x();
}

void loop() {
  if (millis() - lastRead < 2000) {
    delay(10);
    return;
  }

  lastRead = millis();

  if (!sensorReady) {
    Serial.println("Retry SHT40 init");
    sensorReady = initSht4x();
    return;
  }

  readSht4x();
}