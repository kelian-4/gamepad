{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.gamepadServer;
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.evdev
    ps.websockets
    ps.zeroconf
    ps.qrcode
  ]);
  gamepadServerWrapper = pkgs.writeShellScriptBin "gamepad-server" ''
    exec ${pythonEnv}/bin/python3 "$@"
  '';
in
{
  options.programs.gamepadServer = {
    enable = mkEnableOption "environnement pour le serveur de manette virtuelle (uinput, pare-feu, dépendances Python)";

    port = mkOption {
      type = types.port;
      default = 8765;
      description = "Port TCP du serveur WebSocket (et mDNS si activé).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Ouvre le port WebSocket et le port mDNS (5353/udp) dans le pare-feu.";
    };

    screenStream = mkOption {
      type = types.bool;
      default = true;
      description = "Installe les outils de capture et d'encodage (wl-screenrec, wf-recorder, ffmpeg) et ouvre le port du flux vidéo. Le flux reste désactivé tant que le serveur n'est pas lancé avec --stream.";
    };

    streamPort = mkOption {
      type = types.port;
      default = 8766;
      description = "Port TCP du flux vidéo de l'écran (à passer au serveur avec --stream-port si modifié).";
    };
  };

  config = mkIf cfg.enable {
    hardware.uinput.enable = true;

    users.groups.uinput = { };

    services.udev.extraRules = ''
      KERNEL=="uinput", GROUP="uinput", MODE="0660"
    '';

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ] ++ optional cfg.screenStream cfg.streamPort;
      allowedUDPPorts = [ 5353 ];
      extraInputRules = ''
        ip daddr 224.0.0.251 udp dport 5353 accept
      '';
      extraCommands = ''
        iptables -A nixos-fw -d 224.0.0.251 -p udp --dport 5353 -j nixos-fw-accept || true
      '';
      extraStopCommands = ''
        iptables -D nixos-fw -d 224.0.0.251 -p udp --dport 5353 -j nixos-fw-accept || true
      '';
    };

    environment.systemPackages = [ gamepadServerWrapper ]
      ++ optionals cfg.screenStream [
        pkgs.wl-screenrec
        pkgs.wf-recorder
        pkgs.ffmpeg
      ];
  };
}
