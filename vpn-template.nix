# NixOS module for the KarhuHelsinki FortiGate IKEv2 VPN (strongSwan swanctl).
# Import from configuration.nix:   imports = [ ./karhu-vpn.nix ];
#
# Connection is declared here (safe for the Nix store). Secrets are NOT — they
# live in an included file kept out of the world-readable store (see below).

{ config, lib, pkgs, ... }:

let
  # Convenience wrapper: `karhu-vpn up|down|status`. Auto-elevates via sudo
  # since swanctl needs root to reach charon's vici socket.
  karhu-vpn = pkgs.writeShellScriptBin "karhu-vpn" ''
    set -euo pipefail
    if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
    SW=${pkgs.strongswan}/bin/swanctl
    case "''${1:-status}" in
      up)     echo "Connecting karhu VPN..."; "$SW" --initiate --child karhu ;;
      # Terminate the IKE_SA, not just the child: closing only the CHILD_SA leaves
      # the IKE_SA ESTABLISHED, still holding the virtual IP and sending NAT-T
      # keepalives. Killing the IKE_SA takes its children down with it. The
      # `|| true` keeps `down` idempotent under `set -e` when nothing is up.
      down)   echo "Disconnecting karhu VPN..."
              "$SW" --terminate --ike karhu --timeout 5 || true ;;
      status) "$SW" --list-sas ;;
      *)      echo "usage: karhu-vpn {up|down|status}" >&2; exit 1 ;;
    esac
  '';
in
{
  environment.systemPackages = [ karhu-vpn ];

  services.strongswan-swanctl = {
    enable = true;

    swanctl.connections.karhu = {
      remote_addrs  = [ "79.134.107.46" ];
      version       = 2;
      proposals     = [ "aes128-sha256-modp2048" ];
      fragmentation = "yes";
      vips          = [ "0.0.0.0" ];            # request a virtual IP

      # WE authenticate with EAP-MSCHAPv2; IKE identity must be key-id "100".
      local.eap = {
        auth   = "eap-mschapv2";
        eap_id = "<username>";
        id     = "keyid:100";
      };
      # The GATEWAY authenticates to us with the PSK.
      remote.main.auth = "psk";

      children.karhu = {
        remote_ts     = [ "0.0.0.0/0" ];
        esp_proposals = [ "aes128-sha256-modp2048" "aes128-sha256" ];
        # On-demand: nothing dials at boot; bring it up when you want it with
        #   swanctl --initiate --child karhu     (down with: swanctl --terminate --ike karhu)
        # (Avoid "trap" here: a 0.0.0.0/0 trap policy can blackhole your default route.)
        start_action  = "none";
      };
    };

    # Secrets come from a file OUTSIDE the Nix store (the store is world-readable).
    # Point this at whatever your secret manager produces at runtime, e.g.:
    #   sops-nix : config.sops.secrets."karhu-swanctl".path
    #   agenix   : config.age.secrets."karhu-swanctl".path
    # or a hand-created /etc/swanctl/secrets.conf (root-only, mode 600).
    includes = [ "/etc/swanctl/secrets.conf" ];
  };

  # ── The included secrets file must contain (create it out-of-store, chmod 600):
  #
  # secrets {
  #     ike-karhu { secret = "REDACTED" }
  #     eap-karhu {
  #         id     = REDACTED
  #         secret = "REDACTED"
  #     }
  # }
  #
  # The secret file can be created using the following commands:
  # sudo install -d -m 0755 /etc/swanctl
  # sudo install -m 600 /etc/swanctl/secrets.conf
  #
  # After `nixos-rebuild switch`, drive it with the wrapper:
  #   karhu-vpn up        # connect
  #   karhu-vpn status    # expect: karhu ... ESTABLISHED / INSTALLED
  #   karhu-vpn down      # disconnect
}
