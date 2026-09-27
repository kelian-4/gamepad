# Gamepad

Transforme un smartphone en manette virtuelle pour un PC Linux (NixOS), via WebSocket + `uinput`.

## Structure

- `ios/` — app SwiftUI native (iOS), générée via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` + sources dans `ios/Gamepad/`)
- `server/` — serveur Python (`gamepad_server.py`) qui tourne sur la machine Linux cible : reçoit les inputs via WebSocket et crée une manette virtuelle via `evdev`/`uinput`
- `android/` — app Kotlin native (à venir)

## CI

`.github/workflows/ios-build.yml` build l'app iOS sur un runner `macos-latest` (pas besoin de Mac local) :
XcodeGen génère le `.xcodeproj`, `xcodebuild archive` compile sans signature (`CODE_SIGNING_ALLOWED=NO`), puis le `.app` est empaqueté en `.ipa` non signé, publié comme artifact du run.

Pour installer sur un iPhone : télécharger le `.ipa` depuis les artifacts du run GitHub Actions, puis le signer avec **Sideloadly** (ou AltStore) en utilisant un Apple ID gratuit. Limite : l'app expire au bout de 7 jours et doit être re-signée.

## Utilisation

1. Sur la machine Linux (NixOS) : `python3 server/gamepad_server.py`
2. Sur le téléphone : ouvrir l'app, entrer l'IP locale de la machine + le port (8765 par défaut), se connecter.
