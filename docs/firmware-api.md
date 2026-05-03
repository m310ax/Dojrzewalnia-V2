# Firmware API

## HTTP

### GET /

Zwraca prosty panel statusowy urządzenia.

### GET /api/status

Zwraca aktualny stan czujnika, alarmów, przekaźników, ręcznych override'ów i konfiguracji.

### GET /api/config

Zwraca bieżącą konfigurację sterownika.

### POST /api/config

Przyjmuje JSON z wybranymi polami konfiguracyjnymi. Pola są opcjonalne, a wartości są ograniczane do bezpiecznych zakresów.

```json
{
  "targetTemperature": 13.5,
  "targetHumidity": 79,
  "temperatureHysteresis": 0.6,
  "humidityHysteresis": 2.0,
  "mode": "auto"
}
```

Obsługiwane pola:

- `targetTemperature`
- `targetHumidity`
- `temperatureHysteresis`
- `humidityHysteresis`
- `minTemperatureAlarm`
- `maxTemperatureAlarm`
- `minHumidityAlarm`
- `maxHumidityAlarm`
- `pidTempKp`
- `pidTempKi`
- `pidTempKd`
- `pidHumKp`
- `pidHumKi`
- `pidHumKd`
- `mode`

### POST /api/mode

```json
{
  "mode": "auto"
}
```

Dozwolone tryby: `manual`, `auto`, `pid`.

### POST /api/manual

```json
{
  "cooling": false,
  "humidifier": true,
  "dehumidifier": false,
  "fan": true
}
```

Tryb manualny nadal respektuje alarmy, blokadę sprężarki i blokadę jednoczesnego nawilżania oraz osuszania.

## MQTT

### Publikacja statusu

Topic:

```text
devices/<deviceId>/data
```

Przykładowy payload:

```json
{
  "deviceId": "dojrzewalnia-01",
  "mode": "auto",
  "temperature": 12.8,
  "humidity": 79.1,
  "sensorOk": true,
  "sensorStale": false,
  "alarm": false,
  "alarmMessage": "",
  "relays": {
    "cooling": false,
    "humidifier": true,
    "dehumidifier": false,
    "fan": true,
    "coolingAllowed": true
  }
}
```

### Publikacja konfiguracji

Topic:

```text
devices/<deviceId>/config
```

### Subskrybowane topiki sterujące

- `devices/<deviceId>/control/mode`
- `devices/<deviceId>/control/cooling`
- `devices/<deviceId>/control/humidifier`
- `devices/<deviceId>/control/dehumidifier`
- `devices/<deviceId>/control/fan`

Sterowanie przekaźnikami przyjmuje payloady: `true`, `false`, `on`, `off`, `1`, `0`.
