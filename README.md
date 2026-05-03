# Dojrzewalnia

Scalony projekt sterownika dojrzewalni. Repo zawiera aktualnie używane komponenty: firmware ESP32, backend Python, aplikację Flutter, panel VPS oraz dokumentację.

## Aktywne moduły

- firmware ESP32 PlatformIO: `platformio.ini`, `src/`, `include/`
- backend API i MQTT bridge: `server.py`, `ai.py`, `ai_controller.py`, `auto_control.py`
- aplikacja mobilna Flutter: `curing_app/`
- panel VPS i pliki webowe: `vps-panel/`, `templates/`, `nginx.conf`, `docker-compose.yml`
- dokumentacja: `docs/`, `DEPLOY.md`, `releases/`

## Aktualna struktura

- `platformio.ini` i `src/` dla firmware
- `curing_app/` dla aplikacji Flutter
- `server.py` dla backendu
- `vps-panel/` dla panelu serwerowego
- `docs/firmware-api.md` dla opisu API firmware

## Szybki start

1. Firmware: skonfiguruj `include/config.h`, a potem uruchom `platformio run` lub upload z PlatformIO.
2. Backend: zainstaluj zależności z `requirements.txt` i uruchom `server.py` albo cały stack z `docker-compose.yml`.
3. Flutter: przejdź do `curing_app/`, wykonaj `flutter pub get`, potem `flutter run` albo build APK.
4. Panel VPS: uruchom `vps-panel/` tylko jeśli pracujesz nad warstwą panelu webowego.

## Porządek repo

Repo zostało spłaszczone do jednego katalogu roboczego. Stare duplikaty (`android-app`, stare `firmware`, `dojrzewalnia_app`, zagnieżdżone `Dojrzewalnia-V2`) nie są już częścią aktywnego kodu.
