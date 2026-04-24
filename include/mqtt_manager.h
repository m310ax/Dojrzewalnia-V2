#pragma once

void setupMQTT();
void mqttLoop();
void publishData(float temp, float hum);
float getTempMin();
float getTempMax();
float getHumMin();
float getHumMax();
float getTargetTemp();
float getTargetHum();
float getHysteresis();
float getAirTime();
float getAirInterval();
String getProfile();
void setTempRange(float minValue, float maxValue);
void setHumRange(float minValue, float maxValue);
void setTempMin(float value);
void setTempMax(float value);
void setHumMin(float value);
void setHumMax(float value);
void setTargetTemp(float value);
void setTargetHum(float value);
void setHysteresis(float value);
void setAirTime(float value);
void setAirInterval(float value);
void setProfile(const String& value);
bool isMqttConnected();