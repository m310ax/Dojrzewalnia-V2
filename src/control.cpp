#include "control.h"

#include <Arduino.h>

#include "config.h"
#include "mqtt_manager.h"

namespace {
constexpr float kDefaultKp = 2.0F;
float kp = kDefaultKp;
constexpr float kKi = 0.05F;
constexpr float kKd = 1.0F;
constexpr float kMinKp = 0.5F;
constexpr float kMaxKp = 5.0F;
constexpr float kHumDeadband = 1.0F;
constexpr unsigned long kControlIntervalMs = 2000UL;
constexpr unsigned long kFanIntervalMs = 300000UL;
constexpr unsigned long kFanDurationMs = 30000UL;
constexpr unsigned long kHumMinIntervalMs = 60000UL;
constexpr unsigned long kHumMinPulseMs = 500UL;
constexpr unsigned long kHumMaxPulseMs = 5000UL;
constexpr float kIntegralLimit = 1000.0F;

float integral = 0.0F;
float lastError = 0.0F;
float lastHumSample = 0.0F;
unsigned long lastControl = 0;
unsigned long lastMeasure = 0;
unsigned long lastFanRun = 0;
unsigned long lastHumStart = 0;
unsigned long fanStart = 0;
unsigned long humStart = 0;
unsigned long humDuration = 0;
bool fanState = false;
bool humState = false;

void setRelayState(uint8_t pin, bool enabled) {
  digitalWrite(pin, enabled ? HIGH : LOW);
}

void stopHumPulse() {
  setRelayState(RELAY_HUM, false);
  humState = false;
  humStart = 0;
  humDuration = 0;
}

void stopFanCycle(unsigned long now) {
  setRelayState(RELAY_FAN, false);
  fanState = false;
  fanStart = 0;
  lastFanRun = now;
}

void enterFailSafe(unsigned long now) {
  setRelayState(RELAY_COOL, false);
  stopHumPulse();
  stopFanCycle(now);
  integral = 0.0F;
  lastError = 0.0F;
  lastControl = now;
}

void updateTimedOutputs(unsigned long now) {
  if (humState && now - humStart >= humDuration) {
    stopHumPulse();
  }

  if (fanState && now - fanStart >= kFanDurationMs) {
    stopFanCycle(now);
  }
}

void autoTunePID(float hum, unsigned long now) {
  if (lastMeasure != 0 && now - lastMeasure < 5000UL) {
    return;
  }

  if (lastMeasure != 0) {
    const float delta = hum - lastHumSample;
    if (delta > 2.0F) {
      kp *= 0.9F;
    } else if (delta < 0.5F) {
      kp *= 1.1F;
    }

    kp = constrain(kp, kMinKp, kMaxKp);
  }

  lastHumSample = hum;
  lastMeasure = now;
}
}

float getCurrentHumidityKp() {
  return kp;
}

void setCurrentHumidityKp(float value) {
  kp = constrain(value, kMinKp, kMaxKp);
}

void restoreDefaultHumidityPid() {
  kp = kDefaultKp;
}

void initRelays() {
  pinMode(RELAY_COOL, OUTPUT);
  pinMode(RELAY_HUM, OUTPUT);
  pinMode(RELAY_FAN, OUTPUT);

  setRelayState(RELAY_COOL, false);
  setRelayState(RELAY_HUM, false);
  setRelayState(RELAY_FAN, false);
}

void controlLogic(float temp, float hum) {
  const unsigned long now = millis();

  updateTimedOutputs(now);

  if (isnan(temp) || isnan(hum) || hum < 0.0F || hum > 100.0F) {
    enterFailSafe(now);
    return;
  }

  if (isCoolOverrideEnabled()) {
    setRelayState(RELAY_COOL, getCoolOverrideState());
  } else if (temp > getTempMax()) {
    setRelayState(RELAY_COOL, true);
  } else if (temp < getTempMin()) {
    setRelayState(RELAY_COOL, false);
  }

  if (isHumOverrideEnabled()) {
    stopHumPulse();
    setRelayState(RELAY_HUM, getHumOverrideState());
  }

  if (isFanOverrideEnabled()) {
    stopFanCycle(now);
    setRelayState(RELAY_FAN, getFanOverrideState());
  } else if (!fanState && now - lastFanRun >= kFanIntervalMs) {
    setRelayState(RELAY_FAN, true);
    fanState = true;
    fanStart = now;
  }

  if (now - lastControl < kControlIntervalMs) {
    return;
  }

  const float elapsedSeconds = lastControl == 0
      ? static_cast<float>(kControlIntervalMs) / 1000.0F
      : static_cast<float>(now - lastControl) / 1000.0F;
  lastControl = now;

  autoTunePID(hum, now);

  if (!isHumOverrideEnabled()) {
    const float target = (getHumMin() + getHumMax()) * 0.5F;
    const float error = target - hum;

    if (hum > getHumMax()) {
      integral *= 0.5F;
    }

    if (abs(error) < kHumDeadband) {
      lastError = error;
      humDuration = 0;
      return;
    }

    integral = constrain(integral + error * elapsedSeconds, -kIntegralLimit, kIntegralLimit);
    const float derivative = elapsedSeconds > 0.0F ? (error - lastError) / elapsedSeconds : 0.0F;
    const float output = kp * error + kKi * integral + kKd * derivative;
    lastError = error;

    humDuration = constrain(static_cast<int>(output * 100.0F), 0, static_cast<int>(kHumMaxPulseMs));

    if (!humState && humDuration >= kHumMinPulseMs && now - lastHumStart >= kHumMinIntervalMs) {
      setRelayState(RELAY_HUM, true);
      humState = true;
      humStart = now;
      lastHumStart = now;
    }
  }
}