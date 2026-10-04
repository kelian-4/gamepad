{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.gamepadServer;
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.evdev
    ps.websockets
    ps.zeroconf
  ]);
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
  };

  config = mkIf cfg.enable {
    hardware.uinput.enable = true;

    users.groups.uinput = { };

    services.udev.extraRules = ''
      KERNEL=="uinput", GROUP="uinput", MODE="0660"
    '';

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
      allowedUDPPorts = [ 5353 ];
    };

    environment.systemPackages = [ pythonEnv ];
  };
}
