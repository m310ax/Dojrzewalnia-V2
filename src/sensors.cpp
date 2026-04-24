#include <Arduino.h>
#include <Wire.h>
#include "config.h"

namespace {
bool sensorReady = false;
float lastTemperature = 0.0F;
float lastHumidity = 0.0F;
unsigned long lastReconnectAttempt = 0;
uint8_t activeSht4xAddress = 0;
uint8_t cachedSht4xAddress = 0;

constexpr uint8_t kSht4xPrimaryAddress = 0x44;
constexpr uint8_t kSht4xAltAddress = 0x45;
constexpr uint8_t kSht4xSoftResetCommand = 0x94;
constexpr uint8_t kSht4xMeasureHighPrecisionCommand = 0xFD;
constexpr uint8_t kInitAttempts = 3;
constexpr unsigned long kReconnectIntervalMs = 2000;

uint8_t crc8(const uint8_t* data, size_t len) {
  uint8_t crc = 0xFF;

  for (size_t index = 0; index < len; index++) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) ? static_cast<uint8_t>((crc << 1) ^ 0x31) : static_cast<uint8_t>(crc << 1);
    }
  }

  return crc;
}

const char* describeI2cDevice(uint8_t address) {
  switch (address) {
    case 0x3C:
      return "OLED SSD1306/SH1106 @ 0x3C";
    case 0x3D:
      return "OLED SSD1306/SH1106 @ 0x3D";
    case 0x44:
      return "SHT40 @ 0x44";
    case 0x45:
      return "SHT4x @ 0x45";
    default:
      return "nieznane urzadzenie";
  }
}

void reinitWire() {
  Wire.end();
  delay(5);
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(I2C_SPEED);
  Wire.setTimeOut(50);
}

void recoverI2cBus() {
  pinMode(I2C_SDA, INPUT_PULLUP);
  pinMode(I2C_SCL, INPUT_PULLUP);
  delay(2);

  if (digitalRead(I2C_SDA) == HIGH && digitalRead(I2C_SCL) == HIGH) {
    return;
  }

  if (digitalRead(I2C_SDA) == LOW) {
    pinMode(I2C_SCL, OUTPUT_OPEN_DRAIN);
    digitalWrite(I2C_SCL, HIGH);

    for (uint8_t pulse = 0; pulse < 9 && digitalRead(I2C_SDA) == LOW; pulse++) {
      digitalWrite(I2C_SCL, LOW);
      delayMicroseconds(10);
      digitalWrite(I2C_SCL, HIGH);
      delayMicroseconds(10);
    }

    pinMode(I2C_SDA, OUTPUT_OPEN_DRAIN);
    digitalWrite(I2C_SDA, LOW);
    delayMicroseconds(10);
    digitalWrite(I2C_SCL, HIGH);
    delayMicroseconds(10);
    digitalWrite(I2C_SDA, HIGH);
  }

  reinitWire();
}

bool deviceResponds(uint8_t address) {
  Wire.beginTransmission(address);
  return Wire.endTransmission() == 0;
}

bool canSeeSht4x() {
  return deviceResponds(kSht4xPrimaryAddress) || deviceResponds(kSht4xAltAddress);
}

uint8_t resolveSht4xAddress() {
  if (activeSht4xAddress == kSht4xPrimaryAddress || activeSht4xAddress == kSht4xAltAddress) {
    return activeSht4xAddress;
  }

  if (cachedSht4xAddress == kSht4xPrimaryAddress || cachedSht4xAddress == kSht4xAltAddress) {
    if (deviceResponds(cachedSht4xAddress)) {
      activeSht4xAddress = cachedSht4xAddress;
      return activeSht4xAddress;
    }

    cachedSht4xAddress = 0;
  }

  if (deviceResponds(kSht4xPrimaryAddress)) {
    activeSht4xAddress = kSht4xPrimaryAddress;
    cachedSht4xAddress = activeSht4xAddress;
    return activeSht4xAddress;
  }

  if (deviceResponds(kSht4xAltAddress)) {
    activeSht4xAddress = kSht4xAltAddress;
    cachedSht4xAddress = activeSht4xAddress;
    return activeSht4xAddress;
  }

  return 0;
}

bool isI2cBusIdle() {
  pinMode(I2C_SDA, INPUT_PULLUP);
  pinMode(I2C_SCL, INPUT_PULLUP);
  delay(1);
  return digitalRead(I2C_SDA) == HIGH && digitalRead(I2C_SCL) == HIGH;
}

bool decodeSht4xMeasurement(
    const uint8_t* reply,
    float* temperature,
    float* humidity) {
  const bool tempCrcOk = crc8(reply, 2) == reply[2];
  const bool humidityCrcOk = crc8(reply + 3, 2) == reply[5];

  if (!tempCrcOk || !humidityCrcOk) {
    return false;
  }

  const uint16_t rawTemperature = (static_cast<uint16_t>(reply[0]) << 8) | reply[1];
  const uint16_t rawHumidity = (static_cast<uint16_t>(reply[3]) << 8) | reply[4];

  *temperature = -45.0F + 175.0F * static_cast<float>(rawTemperature) / 65535.0F;
  *humidity = -6.0F + 125.0F * static_cast<float>(rawHumidity) / 65535.0F;
  return true;
}

bool readSht4xMeasurement(uint8_t address, float* temperature, float* humidity) {
  if (address == 0) {
    return false;
  }

  Wire.beginTransmission(address);
  Wire.write(kSht4xMeasureHighPrecisionCommand);
  if (Wire.endTransmission() != 0) {
    return false;
  }

  delay(10);

  uint8_t reply[6] = {0};
  const uint8_t measureBytes = Wire.requestFrom(address, static_cast<uint8_t>(6));
  if (measureBytes != 6) {
    return false;
  }

  for (uint8_t index = 0; index < measureBytes; index++) {
    reply[index] = Wire.read();
  }

  return decodeSht4xMeasurement(reply, temperature, humidity);
}

bool initSensorOnce() {
  if (!isI2cBusIdle()) {
    Serial.println("I2C bus blocked - SDA/SCL trzymane w stanie LOW");
    return false;
  }

  activeSht4xAddress = resolveSht4xAddress();
  if (activeSht4xAddress == 0) {
    Serial.println("SHT40 niewidoczny na I2C - brak odpowiedzi z 0x44/0x45");
    return false;
  }

  Wire.beginTransmission(activeSht4xAddress);
  Wire.write(kSht4xSoftResetCommand);
  Wire.endTransmission();

  delay(2);

  if (!readSht4xMeasurement(activeSht4xAddress, &lastTemperature, &lastHumidity)) {
    Serial.println("SHT40 init failed - surowy pomiar nieudany");
    return false;
  }

  return true;
}

bool ensureSensorReady(bool forceRetry = false) {
  if (sensorReady) {
    return true;
  }

  if (!forceRetry && millis() - lastReconnectAttempt < kReconnectIntervalMs) {
    return false;
  }

  lastReconnectAttempt = millis();
  if (!isI2cBusIdle()) {
    recoverI2cBus();
  }

  for (uint8_t attempt = 1; attempt <= kInitAttempts; attempt++) {
    if (initSensorOnce()) {
      sensorReady = true;
      Serial.printf("SHT40 online po probie %u\n", attempt);
      return true;
    }

    delay(50);
    if (!isI2cBusIdle()) {
      recoverI2cBus();
    }
  }

  return false;
}

void refreshMeasurement() {
  if (!ensureSensorReady()) {
    return;
  }

  if (!readSht4xMeasurement(activeSht4xAddress, &lastTemperature, &lastHumidity)) {
    sensorReady = false;
    Serial.println("SHT40 read failed - ponowie inicjalizacje");
  }
}

void scanI2cBus() {
  bool foundDevice = false;

  activeSht4xAddress = 0;
  cachedSht4xAddress = 0;

  Serial.println("I2C scan start");
  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      foundDevice = true;
      if (address == kSht4xPrimaryAddress || address == kSht4xAltAddress) {
        activeSht4xAddress = address;
        cachedSht4xAddress = address;
      }
      Serial.print("I2C device found at 0x");
      if (address < 16) {
        Serial.print('0');
      }
      Serial.print(address, HEX);
      Serial.print(" -> ");
      Serial.println(describeI2cDevice(address));
    }
  }

  if (!foundDevice) {
    Serial.println("I2C scan result: brak urzadzen na magistrali");
  } else {
    Serial.println("I2C scan result: sprawdz czy widac OLED 0x3C/0x3D i SHT40 0x44");
  }

  Serial.println("I2C scan done");
}
}

void setupSensors() {
  delay(150);
  if (!isI2cBusIdle()) {
    recoverI2cBus();
  }
  scanI2cBus();

  if (!ensureSensorReady(true)) {
    Serial.println("SHT40 init failed - sprawdz czujnik, I2C i adres 0x44");
    return;
  }

  refreshMeasurement();
}

float readTemp() {
  refreshMeasurement();
  return lastTemperature;
}

float readHum() {
  refreshMeasurement();
  return lastHumidity;
}

bool isSensorConnected() {
  return sensorReady;
}


