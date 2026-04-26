# Dojrzewalnia-V2 1.0.2

Data wydania: 2026-04-26

## Najważniejsze zmiany

- Naprawiono logowanie aplikacji Flutter dla odpowiedzi backendu zwracających access_token lub token.
- Dodano bardziej precyzyjną diagnostykę błędów połączenia, timeoutu, HTML zamiast API i nieprawidłowego JSON.
- Uspójniono obsługę błędów w głównych wywołaniach API aplikacji mobilnej.
- Naprawiono backendową rejestrację użytkownika: zapis do bazy, hash hasła i obsługa duplikatu adresu email.

## Artefakt Android

- APK release: curing_app/build/app/outputs/flutter-apk/app-release.apk
- Wersja aplikacji: 1.0.2+2

## Walidacja

- flutter analyze dla zmienionych plików zakończył się bez błędów.
- Lokalny test backendu potwierdził poprawne działanie rejestracji i logowania.