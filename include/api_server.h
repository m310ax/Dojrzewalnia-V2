#pragma once

void setupApiServer();
void addToHistory(float temp, float hum);
void apiServerLoop(float temp, float hum);
bool isAppConnected();