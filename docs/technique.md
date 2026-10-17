# Détails techniques

## Structure

- `ios/` : app SwiftUI native, générée avec [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` et sources dans `ios/Gamepad/`).
- `server/` : serveur Python (`gamepad_server.py`) qui reçoit les entrées par WebSocket et crée une manette virtuelle via `evdev`/`uinput`.
- `server/screen_stream.py` : flux de l'écran du PC (voir « Flux de l'écran »), chargé seulement avec `--stream`.
- `nixos/` : module NixOS qui prépare l'environnement (uinput, pare-feu, dépendances Python, outils de capture), sans service systemd.

## CI

`.github/workflows/ios-build.yml` build l'app sur un runner `macos-latest` : XcodeGen génère le `.xcodeproj`, `xcodebuild archive` compile sans signature, puis le `.app` est empaqueté en `.ipa` non signé. Le fichier est publié comme artifact du run, et dans une release GitHub à chaque build sur `main`.

## Serveur

Dépendances : `server/requirements.txt` (`websockets`, `evdev`, `zeroconf`, `qrcode` optionnel).

Diagnostic de l'environnement :

```fish
gamepad-server server/gamepad_server.py doctor
```

Il vérifie `/dev/uinput`, les permissions, la disponibilité de `zeroconf` et affiche l'IP locale.

### Diagnostic de latence (`--diag`)

Avec `--diag`, le serveur affiche chaque seconde où des messages arrivent une ligne :

```
diag: retard boucle moy 0.63 max 11.72 ms | 62 msg | écart max entre pings 151 ms | montée relative moy 0.4 max 2.1 ms | traitement max 0.03 ms | écho max 0.05 ms
```

- **retard boucle** : retard de la boucle asyncio du serveur par rapport à l'horloge. Un max élevé (plusieurs ms) indique que le processus n'a pas eu le CPU à temps.
- **écart max entre pings** : intervalle le plus long entre deux pings reçus de l'iPhone, envoyés toutes les 150 ms. Un écart bien au-dessus de 150 ms alors que le retard de boucle est faible indique un délai avant l'arrivée des données (envoi côté iPhone ou trajet réseau).
- **montée relative** : variation du délai iPhone vers PC seul. Le décalage constant entre les deux horloges est éliminé en retranchant le meilleur délai observé sur les 10 dernières secondes.
- **traitement max / écho max** : temps passé par le serveur à traiter un message et à renvoyer un ping.

## Robustesse

- **Deadman côté serveur** : sans message pendant 1,2 s, le serveur remet tous les boutons et axes au neutre. L'app envoie un ping toutes les 150 ms pour garder la connexion active.
- **Reconnexion côté app** : backoff exponentiel (0,5 s à 10 s) après une perte de connexion établie. Un échec de première connexion ne boucle pas.
- **Identité Xbox 360 émulée** : VID/PID `045e:028e`, reconnue nativement par Steam, Proton et SDL.
- **Handshake versionné** : le client annonce sa version de protocole et sa plateforme, le serveur répond avec les fonctionnalités supportées ou la raison du refus.
- **Multi-manettes** : jusqu'à 4 manettes virtuelles, une par appareil, chacune avec son propre device `uinput`.
- **Cycle de vie iOS** : écran toujours allumé pendant l'utilisation, gestes système différés sur les bords de l'écran.

## Flux de l'écran

Le fond de la manette peut afficher l'écran du PC en direct. La fonction est désactivée par défaut : elle n'existe que si le serveur est lancé avec `--stream`.

```fish
sudo gamepad-server server/gamepad_server.py --stream
```

Options : `--stream-port` (8766 par défaut), `--stream-encoder auto|vaapi|nvenc|x264`. Le diagnostic `gamepad-server server/gamepad_server.py doctor --stream` liste les outils trouvés, la session graphique et les chaînes de capture possibles.

### Architecture

- **Canal séparé.** Un second WebSocket (port 8766) ne transporte que la vidéo. Les entrées, les pings et le deadman restent sur le port 8765 et ne partagent aucune file avec la vidéo.
- **Capture lancée en tant qu'utilisateur.** Le serveur tourne en root sous `sudo`, mais la capture dépend de la session de l'utilisateur. Il retrouve celui-ci par `SUDO_UID` (ou l'unique session `/run/user/<uid>`), puis lance l'outil de capture avec ce compte et l'environnement de sa session (`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `DISPLAY`). Lancé sans `sudo`, le serveur utilise sa propre session. Le processus de capture repasse en ordonnancement normal même si le serveur tourne en temps réel (`chrt -r`).
- **Outils et encodeurs.** Wayland : `wl-screenrec` (VAAPI) puis `wf-recorder` (VAAPI, NVENC ou x264). X11 : `ffmpeg` (`x11grab`). Choix automatique : NVENC si `/dev/nvidiactl` existe, sinon VAAPI si `/dev/dri/renderD128` existe, sinon x264. En mode `auto`, si une chaîne échoue trop vite, la suivante est essayée, avec x264 en dernier recours. La taille de l'écran est lue avec `hyprctl` ou `wlr-randr` quand elle est connue.
- **Aucun coût au repos.** La capture ne démarre que lorsqu'un appareil regarde le flux et s'arrête quand le dernier part.
- **Dépendances.** Aucune dépendance Python en plus. Les outils manquants ne bloquent pas le serveur : il démarre sans flux et indique ce qui manque. Le module NixOS installe `wl-screenrec`, `wf-recorder` et `ffmpeg` (option `programs.gamepadServer.screenStream`) et ouvre le port `streamPort`.

### Sécurité

- Le flux est désactivé sans `--stream`.
- À chaque lancement, le serveur génère un secret aléatoire placé dans le QR code d'appairage (`gamepad://ip:port?s=<secret>`). L'app l'envoie dans le premier message du canal vidéo ; sans le bon secret, aucune image n'est envoyée. Sans terminal ni module `qrcode`, l'adresse complète est écrite dans les journaux du serveur.
- Le secret est comparé en temps constant, et un refus attend une seconde avant de fermer. Il circule en clair sur le réseau local, comme le reste du protocole : n'active le flux que sur un réseau de confiance.
- Deux flux simultanés au maximum.

### Protocole

Capacité facultative annoncée dans le `hello_ack` du port 8765, seulement si la capture est possible :

```json
{"type":"hello_ack","ok":true,"features":["deadman","...","screen_stream"],"streamPort":8766,"streamCodec":"h264","streamProtocol":1}
```

Les anciennes versions de l'app ignorent ces champs, et une app récente face à un serveur sans flux n'affiche pas l'option.

Sur le port du flux, l'app ouvre un WebSocket et envoie en texte :

```json
{"type":"stream_hello","secret":"<secret du QR>","quality":"auto"}
```

`quality` vaut `auto`, `high`, `medium` ou `low` et peut être changé ensuite avec `{"type":"quality","quality":"low"}`. Le serveur répond `{"type":"stream_ack","ok":true,...}` ou `ok:false` avec une `reason`, puis envoie :

- des messages texte `{"type":"stream_status","state":"waiting|active|unavailable|idle","level":"medium","reason":"..."}` ;
- des messages binaires, un par image, dans un format prêt pour VideoToolbox (NAL en AVCC, préfixe de 4 octets) : 1 octet de drapeaux (bit 0 : image clé, bit 1 : paramètres présents), puis si le bit 1 est posé `u16 taille SPS`, SPS, `u16 taille PPS`, PPS, puis les NAL (`u32 taille`, données). Chaque image clé embarque ses paramètres, ce qui permet de démarrer ou reprendre sur n'importe laquelle.

### Latence et réseau

- Chaque appareil a une file de 2 images. Si le réseau ne suit pas, la file est vidée et les images suivantes sont ignorées jusqu'à la prochaine image clé (une par seconde environ) : on jette des images, on n'en met jamais en attente. Un client qui n'absorbe plus rien pendant 2 s est déconnecté du canal vidéo.
- Le tampon d'envoi de la socket vidéo est réduit à 128 Ko pour que les retards remontent vite.
- L'image est affichée dès son arrivée (`DisplayImmediately`) et décodée par le matériel via `AVSampleBufferDisplayLayer`. Le découpage du flux H.264 attend le début de l'image suivante pour fermer l'image courante, soit environ une image de retard.

### Qualité

| Niveau | Hauteur | Images/s | Débit visé |
|---|---|---|---|
| `high` | 720 | 30 | 5 Mbit/s |
| `medium` | 540 | 30 | 3 Mbit/s |
| `low` | 360 | 24 | 1,2 Mbit/s |

En `auto`, le flux démarre en `medium`. Deux abandons d'images en 6 s font baisser d'un niveau (la capture redémarre, une brève coupure) ; 45 s sans abandon font remonter d'un niveau. Un niveau choisi à la main n'est jamais modifié automatiquement ; si plusieurs appareils regardent, le niveau le plus bas demandé s'applique.

### Côté app

`ScreenStreamClient` gère le canal vidéo (connexion, reprise automatique toutes les 3 s, retour à « en attente » après 3 s sans image). Le réglage est dans Réglages > Fond > Écran du PC ; le fond précédent est conservé et réutilisé tant que le flux n'est pas actif. Le flux s'arrête quand l'app quitte l'avant-plan.
