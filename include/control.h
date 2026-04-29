#pragma once

void initRelays();
void controlLogic(float temp, float hum);
float getCurrentHumidityKp();
void setCurrentHumidityKp(float value);
void restoreDefaultHumidityPid();