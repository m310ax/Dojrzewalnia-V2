#pragma once

#include "secrets.h"

// WIFI
#define OTA_HOSTNAME "dojrzewalnia-esp32"
#define OTA_FIRMWARE_VERSION "1.0.0"
#define OTA_VERSION_URL "https://twojadomena.pl/firmware/version.txt"
#define OTA_FIRMWARE_URL "https://twojadomena.pl/firmware/firmware.bin"
#define OTA_CHECK_INTERVAL_MS 3600000UL
#define WIFI_STATIC_IP_1 192
#define WIFI_STATIC_IP_2 168
#define WIFI_STATIC_IP_3 68
#define WIFI_STATIC_IP_4 220
#define WIFI_GATEWAY_1 192
#define WIFI_GATEWAY_2 168
#define WIFI_GATEWAY_3 68
#define WIFI_GATEWAY_4 1
#define WIFI_SUBNET_1 255
#define WIFI_SUBNET_2 255
#define WIFI_SUBNET_3 255
#define WIFI_SUBNET_4 0

// MQTT
#define MQTT_PORT 8883
#define MQTT_CLIENT_ID "ESP32"
#define MQTT_DEVICE_ID "esp1"

// PINY
#define RELAY_COOL 5
#define RELAY_HUM  18
#define RELAY_FAN  19

// I2C
#define I2C_SDA 21
#define I2C_SCL 22
#define I2C_SPEED 100000L

// OLED SSD1306 I2C
#define OLED_ADDR -1
#define OLED_WIDTH 128
#define OLED_HEIGHT 64
#define OLED_RESET -1
#define OLED_FLIP 0
#define OLED_INVERT 0

// Uklad ekranu statusu: 1 = wariant dostrojony pod panel 2,4", 0 = uklad gestszy
#define DISPLAY_LAYOUT_24 1