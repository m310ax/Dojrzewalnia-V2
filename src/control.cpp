#include <Arduino.h>
#include "config.h"
#include "mqtt_manager.h"

void initRelays() {
  pinMode(RELAY_COOL, OUTPUT);
  pinMode(RELAY_HUM, OUTPUT);
  pinMode(RELAY_FAN, OUTPUT);
}

void controlLogic(float temp, float hum) {
  if (!isMqttConnected()) {
    digitalWrite(
        RELAY_COOL,
        isCoolOverrideEnabled() ? (getCoolOverrideState() ? HIGH : LOW) : (temp > 3.0F ? HIGH : LOW));
    digitalWrite(RELAY_HUM, hum < 75.0F ? HIGH : LOW);
    digitalWrite(RELAY_FAN, isFanOverrideEnabled() && !getFanOverrideState() ? LOW : HIGH);
    return;
  }

  if (isCoolOverrideEnabled()) {
    digitalWrite(RELAY_COOL, getCoolOverrideState() ? HIGH : LOW);
  } else {
    if (temp > getTempMax()) {
      digitalWrite(RELAY_COOL, HIGH);
    } else if (temp < getTempMin()) {
      digitalWrite(RELAY_COOL, LOW);
    }
  }

  if (hum < getHumMin()) {
    digitalWrite(RELAY_HUM, HIGH);
  } else if (hum > getHumMax()) {
    digitalWrite(RELAY_HUM, LOW);
  }

  digitalWrite(RELAY_FAN, isFanOverrideEnabled() && !getFanOverrideState() ? LOW : HIGH);
}