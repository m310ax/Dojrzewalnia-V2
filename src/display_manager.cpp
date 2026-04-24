#include <Arduino.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <Fonts/Org_01.h>

#include "api_server.h"
#include "config.h"
#include "mqtt_manager.h"
#include "sensors.h"
#include "wifi_manager.h"

namespace {
Adafruit_SH1106G display(OLED_WIDTH, OLED_HEIGHT, &Wire, OLED_RESET);
bool displayReady = false;
unsigned long lastRefresh = 0;

constexpr int kCompactFontBaselineOffset = 6;
constexpr unsigned long kStatusPageDurationMs = 4000;

#if DISPLAY_LAYOUT_24
constexpr int kDisplayLeftPadding = 2;
constexpr int kBootTitleY = 4;
constexpr int kBootStatusY = 20;
constexpr int kDiagTitleY = 2;
constexpr int kDiagLine1Y = 18;
constexpr int kDiagLine2Y = 32;
constexpr int kDiagLine3Y = 46;
constexpr int kStatusTempY = 2;
constexpr int kStatusHumidityY = 14;
constexpr int kStatusTempRangeY = 26;
constexpr int kStatusHumidityRangeY = 38;
constexpr int kStatusWifiY = 50;
constexpr int kStatusIpY = 58;
constexpr int kStatusLabel1Y = 2;
constexpr int kStatusValue1Y = 10;
constexpr int kStatusLabel2Y = 22;
constexpr int kStatusValue2Y = 30;
constexpr int kStatusLabel3Y = 42;
constexpr int kStatusValue3Y = 50;
constexpr char kTemperatureFormat[] = "Temperatura: %.1fC";
constexpr char kHumidityFormat[] = "Wilgotność: %.1f%%";
constexpr char kTemperatureRangeFormat[] = "Temperatura zadana: %.1f..%.1fC";
constexpr char kHumidityRangeFormat[] = "Wilgotność zadana: %.0f..%.0f%%";
constexpr char kWifiOnlineText[] = "Stan połączenia WiFi: OK";
constexpr char kWifiOfflineText[] = "Stan połączenia WiFi: OFF";
#else
constexpr int kDisplayLeftPadding = 0;
constexpr int kBootTitleY = 0;
constexpr int kBootStatusY = 18;
constexpr int kDiagTitleY = 0;
constexpr int kDiagLine1Y = 18;
constexpr int kDiagLine2Y = 34;
constexpr int kDiagLine3Y = 50;
constexpr int kStatusTempY = 0;
constexpr int kStatusHumidityY = 10;
constexpr int kStatusTempRangeY = 20;
constexpr int kStatusHumidityRangeY = 30;
constexpr int kStatusWifiY = 40;
constexpr int kStatusIpY = 50;
constexpr char kTemperatureFormat[] = "Temperatura: %.1fC";
constexpr char kHumidityFormat[] = "Wilgotność: %.1f%%";
constexpr char kTemperatureRangeFormat[] = "Zakres T: %.1f-%.1fC";
constexpr char kHumidityRangeFormat[] = "Zakres H: %.0f-%.0f%%";
constexpr char kWifiOnlineText[] = "WiFi połączone";
constexpr char kWifiOfflineText[] = "WiFi offline";
#endif

constexpr int kCompactEllipsisDots = 3;

char getPolishBaseChar(uint16_t codepoint) {
  switch (codepoint) {
    case 0x0105:
      return 'a';
    case 0x0107:
      return 'c';
    case 0x0119:
      return 'e';
    case 0x0142:
      return 'l';
    case 0x0144:
      return 'n';
    case 0x00F3:
      return 'o';
    case 0x015B:
      return 's';
    case 0x017A:
      return 'z';
    case 0x017C:
      return 'z';
    case 0x0104:
      return 'A';
    case 0x0106:
      return 'C';
    case 0x0118:
      return 'E';
    case 0x0141:
      return 'L';
    case 0x0143:
      return 'N';
    case 0x00D3:
      return 'O';
    case 0x015A:
      return 'S';
    case 0x0179:
      return 'Z';
    case 0x017B:
      return 'Z';
    default:
      return '\0';
  }
}

int getCompactFontAdvance(char character) {
  if (character < Org_01.first || character > Org_01.last) {
    return 4;
  }

  const auto* glyph = &Org_01Glyphs[character - Org_01.first];
  return glyph->xAdvance;
}

int writeCompactChar(int x, int y, char character) {
  display.setCursor(x, y + kCompactFontBaselineOffset);
  display.write(character);
  return getCompactFontAdvance(character);
}

void drawCompactAcuteAccent(int x, int y) {
  display.drawPixel(x + 2, y, SH110X_WHITE);
  display.drawPixel(x + 3, y + 1, SH110X_WHITE);
}

void drawCompactDotAccent(int x, int y) {
  display.drawPixel(x + 1, y, SH110X_WHITE);
}

void drawCompactOgonekAccent(int x, int y) {
  display.drawPixel(x + 2, y + 5, SH110X_WHITE);
  display.drawPixel(x + 3, y + 6, SH110X_WHITE);
}

void drawCompactStrokeAccent(int x, int y) {
  display.drawLine(x + 1, y + 4, x + 3, y + 2, SH110X_WHITE);
}

int writeCompactPolishGlyph(int x, int y, uint16_t codepoint) {
  char baseChar = getPolishBaseChar(codepoint);
  if (baseChar == '\0') {
    return 0;
  }

  const int advance = writeCompactChar(x, y, baseChar);

  switch (codepoint) {
    case 0x0105:
    case 0x0119:
    case 0x0104:
    case 0x0118:
      drawCompactOgonekAccent(x, y);
      break;
    case 0x0107:
    case 0x0144:
    case 0x00F3:
    case 0x015B:
    case 0x017A:
    case 0x0106:
    case 0x0143:
    case 0x00D3:
    case 0x015A:
    case 0x0179:
      drawCompactAcuteAccent(x, y);
      break;
    case 0x017C:
    case 0x017B:
      drawCompactDotAccent(x, y);
      break;
    case 0x0142:
    case 0x0141:
      drawCompactStrokeAccent(x, y);
      break;
    default:
      break;
  }

  return advance;
}

void drawScaledPixel(int x, int y, int textSize) {
  display.fillRect(x, y, textSize, textSize, SH110X_WHITE);
}

void drawAcuteAccent(int x, int y, int textSize) {
  drawScaledPixel(x + 3 * textSize, y, textSize);
  drawScaledPixel(x + 4 * textSize, y + textSize, textSize);
}

void drawDotAccent(int x, int y, int textSize) {
  drawScaledPixel(x + 2 * textSize, y, textSize);
}

void drawOgonekAccent(int x, int y, int textSize) {
  drawScaledPixel(x + 3 * textSize, y + 6 * textSize, textSize);
  drawScaledPixel(x + 4 * textSize, y + 7 * textSize, textSize);
}

void drawStrokeAccent(int x, int y, int textSize) {
  display.drawLine(
      x + textSize,
      y + 5 * textSize,
      x + 4 * textSize,
      y + 2 * textSize,
      SH110X_WHITE);
}

bool drawPolishGlyph(int x, int y, uint16_t codepoint, int textSize) {
  char baseChar = '\0';

  switch (codepoint) {
    case 0x0105:
      baseChar = 'a';
      break;
    case 0x0107:
      baseChar = 'c';
      break;
    case 0x0119:
      baseChar = 'e';
      break;
    case 0x0142:
      baseChar = 'l';
      break;
    case 0x0144:
      baseChar = 'n';
      break;
    case 0x00F3:
      baseChar = 'o';
      break;
    case 0x015B:
      baseChar = 's';
      break;
    case 0x017A:
      baseChar = 'z';
      break;
    case 0x017C:
      baseChar = 'z';
      break;
    case 0x0104:
      baseChar = 'A';
      break;
    case 0x0106:
      baseChar = 'C';
      break;
    case 0x0118:
      baseChar = 'E';
      break;
    case 0x0141:
      baseChar = 'L';
      break;
    case 0x0143:
      baseChar = 'N';
      break;
    case 0x00D3:
      baseChar = 'O';
      break;
    case 0x015A:
      baseChar = 'S';
      break;
    case 0x0179:
      baseChar = 'Z';
      break;
    case 0x017B:
      baseChar = 'Z';
      break;
    default:
      return false;
  }

  display.drawChar(x, y, baseChar, SH110X_WHITE, SH110X_BLACK, textSize, textSize);

  switch (codepoint) {
    case 0x0105:
    case 0x0119:
    case 0x0104:
    case 0x0118:
      drawOgonekAccent(x, y, textSize);
      return true;
    case 0x0107:
    case 0x0144:
    case 0x00F3:
    case 0x015B:
    case 0x017A:
    case 0x0106:
    case 0x0143:
    case 0x00D3:
    case 0x015A:
    case 0x0179:
      drawAcuteAccent(x, y, textSize);
      return true;
    case 0x017C:
    case 0x017B:
      drawDotAccent(x, y, textSize);
      return true;
    case 0x0142:
    case 0x0141:
      drawStrokeAccent(x, y, textSize);
      return true;
    default:
      return true;
  }
}

void writeLine(int x, int y, const char* text, int textSize = 1) {
  if (textSize == 1) {
    int cursorX = x;
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(text);
    const int lineRightEdge = OLED_WIDTH;
    const int ellipsisAdvance = getCompactFontAdvance('.') * kCompactEllipsisDots;

    display.setFont(&Org_01);

    while (*bytes != 0) {
      if (*bytes < 0x80) {
        const char character = static_cast<char>(*bytes);
        const int advance = getCompactFontAdvance(character);
        const bool hasMoreText = bytes[1] != 0;
        const int reservedAdvance = hasMoreText ? ellipsisAdvance : 0;

        if (cursorX + advance + reservedAdvance > lineRightEdge) {
          while (cursorX + ellipsisAdvance <= lineRightEdge && kCompactEllipsisDots > 0) {
            cursorX += writeCompactChar(cursorX, y, '.');
            if (cursorX + getCompactFontAdvance('.') > lineRightEdge) {
              break;
            }
            if (cursorX + getCompactFontAdvance('.') * 2 > lineRightEdge) {
              break;
            }
          }
          break;
        }

        cursorX += writeCompactChar(cursorX, y, character);
        bytes++;
        continue;
      }

      if (bytes[1] == 0) {
        break;
      }

      const uint16_t codepoint = (static_cast<uint16_t>(*bytes & 0x1F) << 6) |
          static_cast<uint16_t>(bytes[1] & 0x3F);

      const char baseChar = getPolishBaseChar(codepoint);
      const int advance = (baseChar == '\0') ? 0 : getCompactFontAdvance(baseChar);
      const bool hasMoreText = bytes[2] != 0;
      const int reservedAdvance = hasMoreText ? ellipsisAdvance : 0;

      if (advance > 0 && cursorX + advance + reservedAdvance > lineRightEdge) {
        for (int dotIndex = 0; dotIndex < kCompactEllipsisDots; ++dotIndex) {
          const int dotAdvance = getCompactFontAdvance('.');
          if (cursorX + dotAdvance > lineRightEdge) {
            break;
          }
          cursorX += writeCompactChar(cursorX, y, '.');
        }
        break;
      }

      const int glyphAdvance = writeCompactPolishGlyph(cursorX, y, codepoint);
      if (glyphAdvance > 0) {
        cursorX += glyphAdvance;
      }

      bytes += 2;
    }

    display.setFont(nullptr);
    return;
  }

  int cursorX = x;
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(text);

  while (*bytes != 0) {
    if (*bytes < 0x80) {
      display.drawChar(cursorX, y, *bytes, SH110X_WHITE, SH110X_BLACK, textSize, textSize);
      cursorX += 6 * textSize;
      bytes++;
      continue;
    }

    if (bytes[1] == 0) {
      break;
    }

    const uint16_t codepoint = (static_cast<uint16_t>(*bytes & 0x1F) << 6) |
        static_cast<uint16_t>(bytes[1] & 0x3F);

    if (drawPolishGlyph(cursorX, y, codepoint, textSize)) {
      cursorX += 6 * textSize;
    }

    bytes += 2;
  }
}

void showDiagnosticMessage(const char* line1, const char* line2, const char* line3) {
  display.clearDisplay();
  writeLine(kDisplayLeftPadding, kDiagTitleY, "DIAGNOSTYKA", 1);
  writeLine(kDisplayLeftPadding, kDiagLine1Y, line1, 1);
  writeLine(kDisplayLeftPadding, kDiagLine2Y, line2, 1);
  writeLine(kDisplayLeftPadding, kDiagLine3Y, line3, 1);
  display.display();
}

void showStatusPair(int labelY, int valueY, const char* label, const char* value) {
  writeLine(kDisplayLeftPadding, labelY, label, 1);
  writeLine(kDisplayLeftPadding, valueY, value, 1);
}
}

void initDisplay() {
  delay(250);

  if (!display.begin(0x3C, true) && !display.begin(0x3D, true)) {
    Serial.println("OLED init failed - sprawdz zasilanie, SDA/SCL i adres 0x3C/0x3D");
    return;
  }

  displayReady = true;
  display.clearDisplay();
  display.setTextColor(SH110X_WHITE);
  writeLine(kDisplayLeftPadding, kBootTitleY, "Sterownik startuje", 1);
  writeLine(kDisplayLeftPadding, kBootStatusY, "OLED online", 1);
  display.display();
}

void updateDisplay(float temp, float hum) {
  if (!displayReady) {
    return;
  }

  if (millis() - lastRefresh < 500) {
    return;
  }

  lastRefresh = millis();

  if (!isSensorConnected()) {
    showDiagnosticMessage(
        "SHT40 ERR",
        "Sprawdz I2C i zasilanie",
        "SDA/SCL + adres 0x44");
    return;
  }

  char buffer[48];

  display.clearDisplay();

#if DISPLAY_LAYOUT_24
  const bool showPrimaryPage = ((millis() / kStatusPageDurationMs) % 2) == 0;

  if (showPrimaryPage) {
    snprintf(buffer, sizeof(buffer), "%.1fC", temp);
    showStatusPair(kStatusLabel1Y, kStatusValue1Y, "Temperatura", buffer);

    snprintf(buffer, sizeof(buffer), "%.1f%%", hum);
    showStatusPair(kStatusLabel2Y, kStatusValue2Y, "Wilgotność", buffer);

    snprintf(buffer, sizeof(buffer), "%s", getLocalIp());
    showStatusPair(kStatusLabel3Y, kStatusValue3Y, "IP", buffer);
  } else {
    snprintf(buffer, sizeof(buffer), "%.1f..%.1fC", getTempMin(), getTempMax());
    showStatusPair(kStatusLabel1Y, kStatusValue1Y, "Temperatura zadana", buffer);

    snprintf(buffer, sizeof(buffer), "%.0f..%.0f%%", getHumMin(), getHumMax());
    showStatusPair(kStatusLabel2Y, kStatusValue2Y, "Wilgotność zadana", buffer);

    showStatusPair(
        kStatusLabel3Y,
        kStatusValue3Y,
        "Stan połączenia WiFi",
        isWiFiConnected() ? "OK" : "OFF");
  }

  display.display();
  return;
#endif

  snprintf(buffer, sizeof(buffer), kTemperatureFormat, temp);
  writeLine(kDisplayLeftPadding, kStatusTempY, buffer, 1);

  snprintf(buffer, sizeof(buffer), kHumidityFormat, hum);
  writeLine(kDisplayLeftPadding, kStatusHumidityY, buffer, 1);

  snprintf(buffer, sizeof(buffer), kTemperatureRangeFormat, getTempMin(), getTempMax());
  writeLine(kDisplayLeftPadding, kStatusTempRangeY, buffer, 1);

  snprintf(buffer, sizeof(buffer), kHumidityRangeFormat, getHumMin(), getHumMax());
  writeLine(kDisplayLeftPadding, kStatusHumidityRangeY, buffer, 1);

  writeLine(kDisplayLeftPadding, kStatusWifiY, isWiFiConnected() ? kWifiOnlineText : kWifiOfflineText, 1);

  snprintf(buffer, sizeof(buffer), "IP: %s", getLocalIp());
  writeLine(kDisplayLeftPadding, kStatusIpY, buffer, 1);

  display.display();
}