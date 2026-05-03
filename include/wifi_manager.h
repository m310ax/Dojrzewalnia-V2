#pragma once
void setupWiFi();
void setupOTA();
void handleOTA();
void checkHttpOta();
void requestHttpOtaCheck();
bool isHttpOtaCheckPending();
bool isOtaInProgress();
bool isWiFiConnected();
const char* getLocalIp();