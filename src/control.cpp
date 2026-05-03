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
#ifdef COOLING_MIN_ON_MS
constexpr unsigned long kCoolingMinOnMs = COOLING_MIN_ON_MS;
#else
constexpr unsigned long kCoolingMinOnMs = 120000UL;
#endif
#ifdef COOLING_MIN_OFF_MS
constexpr unsigned long kCoolingMinOffMs = COOLING_MIN_OFF_MS;
#else
constexpr unsigned long kCoolingMinOffMs = 180000UL;
#endif
constexpr unsigned long kFanIntervalMs = 300000UL;
constexpr unsigned long kFanDurationMs = 30000UL;
constexpr unsigned long kHumMinIntervalMs = 60000UL;
constexpr unsigned long kHumMinPulseMs = 500UL;
constexpr unsigned long kHumMaxPulseMs = 5000UL;
constexpr float kIntegralLimit = 1000.0F;

float integral = 0.0F;
float lastError = 0.0F;
float lastHumSample = 0.0F;
float lastCoolingTarget = NAN;
float lastCoolingHysteresis = NAN;
unsigned long lastControl = 0;
unsigned long lastMeasure = 0;
unsigned long lastFanRun = 0;
unsigned long lastHumStart = 0;
unsigned long coolingLastOn = 0;
unsigned long coolingLastOff = 0;
unsigned long fanStart = 0;
unsigned long humStart = 0;
unsigned long humDuration = 0;
bool fanState = false;
bool humState = false;
bool coolingState = false;
bool coolingPullDownActive = false;

void setRelayState(uint8_t pin, bool enabled) {
  digitalWrite(pin, enabled ? LOW : HIGH);
}

bool canStartCooling(unsigned long now) {
  return !coolingState && (coolingLastOff == 0 || now - coolingLastOff >= kCoolingMinOffMs);
}

bool canStopCooling(unsigned long now) {
  return coolingState && (coolingLastOn == 0 || now - coolingLastOn >= kCoolingMinOnMs);
}

void setCoolingRelayState(unsigned long now, bool enabled) {
  if (coolingState == enabled) {
    return;
  }

  coolingState = enabled;
  setRelayState(RELAY_COOL, enabled);

  if (enabled) {
    coolingLastOn = now;
  } else {
    coolingLastOff = now;
  }
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
  setCoolingRelayState(now, false);
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

  coolingState = false;
  coolingLastOn = 0;
  coolingLastOff = 0;
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
    setCoolingRelayState(now, getCoolOverrideState());
  } else {
    const float targetTemp = getTargetTemp();
    const float tempHysteresis = getTempHysteresis();
    const bool targetChanged = !isfinite(lastCoolingTarget) || !isfinite(lastCoolingHysteresis)
        || fabsf(lastCoolingTarget - targetTemp) > 0.01F
        || fabsf(lastCoolingHysteresis - tempHysteresis) > 0.01F;

    if (targetChanged) {
      coolingPullDownActive = temp > targetTemp;
      lastCoolingTarget = targetTemp;
      lastCoolingHysteresis = tempHysteresis;
    }

    if (coolingPullDownActive) {
      if (temp <= targetTemp && canStopCooling(now)) {
        coolingPullDownActive = false;
        setCoolingRelayState(now, false);
      } else if (canStartCooling(now)) {
        setCoolingRelayState(now, true);
      }
    } else {
      const float tempOnThreshold = targetTemp + tempHysteresis;
      const float tempOffThreshold = targetTemp;
      if (temp >= tempOnThreshold && canStartCooling(now)) {
        setCoolingRelayState(now, true);
      } else if (temp <= tempOffThreshold && canStopCooling(now)) {
        setCoolingRelayState(now, false);
      }
    }
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

  if (!isHumOverrideEnabled()) {
    const float humOnThreshold = getTargetHum() - getHumHysteresis();
    const float humOffThreshold = getTargetHum();

    if (hum <= humOnThreshold) {
      setRelayState(RELAY_HUM, true);
      humState = true;
      humStart = now;
      humDuration = kControlIntervalMs + 250UL;
    } else if (hum >= humOffThreshold) {
      stopHumPulse();
    }
  }
}