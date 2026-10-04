# Module NixOS

Pas de service systemd (choix explicite) : ce module prépare seulement l'environnement
(uinput, utilisateur dans le bon groupe, pare-feu, dépendances Python). Le serveur se lance
toujours à la main, avec `chrt` si besoin de latence réduite sous charge CPU.

## Utilisation

Dans ta configuration NixOS :

```nix
{
  imports = [ /chemin/vers/gamepad/nixos/module.nix ];

  programs.gamepadServer = {
    enable = true;
    port = 8765;        # optionnel, défaut 8765
    openFirewall = true; # optionnel, défaut true
  };

  users.users.<TON_UTILISATEUR>.extraGroups = [ "uinput" ];
}
```

Puis `sudo nixos-rebuild switch`, se déconnecter/reconnecter (ou redémarrer) pour que
l'appartenance au groupe `uinput` soit prise en compte, et lancer le serveur normalement :

```fish
cd gamepad
sudo chrt -r 10 python3 server/gamepad_server.py
```

ou sans `chrt` si pas besoin de latence réduite :

```fish
python3 server/gamepad_server.py
```

Diagnostic rapide de l'environnement :

```fish
python3 server/gamepad_server.py doctor
```
