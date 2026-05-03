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
  if (textSize == 0) {
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

void drawWifiIcon(int x, int y, bool connected) {
  display.drawCircle(x + 4, y + 7, 4, SH110X_WHITE);
  display.drawCircle(x + 4, y + 7, 2, SH110X_WHITE);
  display.fillRect(x + 3, y + 7, 2, 2, SH110X_WHITE);
  if (!connected) {
    display.drawLine(x, y + 11, x + 8, y + 3, SH110X_WHITE);
  }
}

void drawServerIcon(int x, int y, bool connected) {
  display.drawRoundRect(x, y + 1, 10, 6, 1, SH110X_WHITE);
  display.drawRoundRect(x, y + 8, 10, 6, 1, SH110X_WHITE);
  if (connected) {
    display.fillRect(x + 7, y + 3, 2, 2, SH110X_WHITE);
    display.fillRect(x + 7, y + 10, 2, 2, SH110X_WHITE);
  } else {
    display.drawLine(x + 1, y + 12, x + 9, y + 2, SH110X_WHITE);
  }
}

void drawAppIcon(int x, int y, bool connected) {
  display.drawRoundRect(x + 1, y, 8, 13, 2, SH110X_WHITE);
  display.drawFastHLine(x + 3, y + 2, 4, SH110X_WHITE);
  display.drawPixel(x + 5, y + 10, SH110X_WHITE);
  if (!connected) {
    display.drawLine(x, y + 12, x + 10, y + 1, SH110X_WHITE);
  }
}

void drawStatusIcons(bool wifiConnected, bool mqttConnected, bool appConnected) {
  const int appX = OLED_WIDTH - 10;
  const int mqttX = appX - 12;
  const int wifiX = mqttX - 12;
  drawWifiIcon(wifiX, 0, wifiConnected);
  drawServerIcon(mqttX, 0, mqttConnected);
  drawAppIcon(appX, 0, appConnected);
}

void drawBandDivider(int y) {
  display.drawFastHLine(2, y, OLED_WIDTH - 4, SH110X_WHITE);
}

void drawTargetMini(int x, int y, const char* value) {
  writeLine(x, y, "CEL", 1);
  writeLine(x, y + 10, value, 1);
}

void drawMetricBand(
    int y,
    const char* label,
    const char* currentValue,
    const char* targetValue,
    const char* unit) {
  writeLine(4, y, label, 1);
  writeLine(4, y + 11, currentValue, 2);
  writeLine(58, y + 15, unit, 1);
  display.drawFastVLine(80, y + 1, 20, SH110X_WHITE);
  drawTargetMini(89, y + 1, targetValue);
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

  char tempCurrent[16];
  char tempTarget[16];
  char tempHysteresis[16];
  char humCurrent[16];
  char humTarget[16];
  char humHysteresis[16];

  display.clearDisplay();

  snprintf(tempCurrent, sizeof(tempCurrent), "%.1fC", temp);
  snprintf(tempTarget, sizeof(tempTarget), "%.1fC", getTargetTemp());
  snprintf(tempHysteresis, sizeof(tempHysteresis), "%.1fC", getTempHysteresis());
  snprintf(humCurrent, sizeof(humCurrent), "%.0f%%", hum);
  snprintf(humTarget, sizeof(humTarget), "%.0f%%", getTargetHum());
  snprintf(humHysteresis, sizeof(humHysteresis), "%.1f%%", getHumHysteresis());

  writeLine(2, 2, "Temperatura", 1);
  writeLine(66, 2, "Wilgotnosc", 1);

  writeLine(2, 12, tempCurrent, 2);
  writeLine(66, 12, humCurrent, 2);

  display.drawFastVLine(63, 2, OLED_HEIGHT - 4, SH110X_WHITE);

  writeLine(2, 32, "Zadana", 1);
  writeLine(2, 40, tempTarget, 1);
  writeLine(2, 48, "Histereza", 1);
  writeLine(2, 56, tempHysteresis, 1);

  writeLine(66, 32, "Zadana", 1);
  writeLine(66, 40, humTarget, 1);
  writeLine(66, 48, "Histereza", 1);
  writeLine(66, 56, humHysteresis, 1);

  display.display();
}