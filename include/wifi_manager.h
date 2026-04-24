#pragma once
void setupWiFi();
void setupOTA();
void handleOTA();
void checkHttpOta();
bool isOtaInProgress();
bool isWiFiConnected();
const char* getLocalIp();