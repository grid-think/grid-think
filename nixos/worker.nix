# Live worker OS: boots straight into a grid worker. Nothing is installed,
# nothing is written to disk. Flash, boot, it joins the grid by itself.
{
  config,
  lib,
  pkgs,
  modulesPath,
  gridLlamaRpc,
  gridAgent,
  gridSshKeys,
  ...
}:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  system.stateVersion = "25.05";

  networking.hostName = "worker";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [
    22
    50052
  ];

  users.users.worker = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = gridSshKeys;
  };
  security.sudo.wheelNeedsPassword = false;
  services.getty.autologinUser = lib.mkDefault "worker";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Retired laptops often need proprietary firmware to boot at all.
  # Scoped to this image only; set enableAllFirmware=false for a fully-free build.
  nixpkgs.config.allowUnfree = true;
  hardware.enableAllFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkIf pkgs.stdenv.hostPlatform.isx86 true;
  hardware.cpu.amd.updateMicrocode = lib.mkIf pkgs.stdenv.hostPlatform.isx86 true;
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      mesa
      vulkan-loader
    ];
  };
  boot.initrd.availableKernelModules =
    [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "virtio_net"
      "ahci"
      "xhci_pci"
      "ehci_pci"
      "usb_storage"
      "sd_mod"
      "sr_mod"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [
      "e1000"
      "e1000e"
      "igb"
      "r8169"
      "i915"
      "amdgpu"
      "radeon"
    ];
  boot.kernelModules = lib.optionals pkgs.stdenv.hostPlatform.isx86 [
    "kvm-intel"
    "kvm-amd"
  ];

  environment.systemPackages = [
    gridLlamaRpc
    gridAgent
    pkgs.htop
    pkgs.iperf3
    pkgs.pciutils
    pkgs.usbutils
  ];

  systemd.services.grid-worker = {
    description = "grid-think RPC worker (llama.cpp tensor math for coordinator)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${gridLlamaRpc}/bin/rpc-server -H 0.0.0.0 -p 50052 -c";
      Restart = "always";
      RestartSec = 5;
      User = "worker";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  documentation.enable = false;
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";
  isoImage.volumeID = "GRID_WORKER";
}
