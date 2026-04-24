## Deploy

1. Skopiuj `.env.example` do `.env` i ustaw `JWT_SECRET_KEY`, `FCM_SERVER_KEY` oraz w razie potrzeby `PORT`.
2. Umieść aktualny firmware ESP w `releases/firmware.bin`.
3. Ustaw numer wersji OTA w `releases/version.txt` i dopasuj `OTA_FIRMWARE_VERSION` w `include/config.h` dla bieżącego buildu firmware.
4. Uruchom `docker-compose up -d --build`.
5. Skonfiguruj domenę tak, aby wskazywała na host z nginx.

## HTTPS

Na serwerze hosta:

1. `sudo apt install certbot python3-certbot-nginx`
2. `sudo certbot --nginx -d twojadomena.pl`

## OTA

Firmware sprawdza `OTA_VERSION_URL` co `OTA_CHECK_INTERVAL_MS`.

1. Wgraj nowe `firmware.bin` do `releases/`.
2. Zwiększ `releases/version.txt`.
3. ESP pobierze aktualizację po wykryciu nowszej wersji.

## Android Release

1. `flutter build apk --release`
2. APK znajdziesz w `curing_app/build/app/outputs/flutter-apk/app-release.apk`
3. Dla Google Play użyj `flutter build appbundle`

## Monitoring

Minimum na start:

1. logi Docker: `docker-compose logs -f backend nginx`
2. healthcheck API: `curl http://localhost/health`

## Mikr.us

Przy uruchamianiu bez reverse proxy backend może nasłuchiwać bezpośrednio na porcie `20551`, zgodnie z `PORT=20551`.