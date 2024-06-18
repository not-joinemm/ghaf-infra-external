# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  self,
  inputs,
  pkgs,
  ...
}: let
  # Vendored in until our nixpkgs pin includes https://github.com/NixOS/nixpkgs/pull/302833.
  brainstem = pkgs.callPackage ./brainstem.nix {};
  jenkins-connection-script = pkgs.writeScript "jenkins-connect.sh" ''
    #!/usr/bin/env bash
    set -eu
    if [ ! -f agent.jar ]; then echo "Error: /var/lib/jenkins/agent.jar not found"; exit 1; fi;
    if [ ! -f secret-file ]; then echo "Error: /var/lib/jenkins/secret-file not found"; exit 1; fi;
    ${pkgs.jdk}/bin/java \
      -jar agent.jar \
      -jnlpUrl https://ghaf-jenkins-controller-villepekkajuntun.northeurope.cloudapp.azure.com/computer/testagent/jenkins-agent.jnlp \
      -secret @secret-file \
      -workDir "/var/lib/jenkins"
  '';
in {
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ]
    ++ (with inputs; [
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ])
    ++ (with self.nixosModules; [
      common
      service-openssh
      user-tervis
      user-vjuntunen
      user-flokli
      user-jrautiola
      user-mariia
      user-hrosten
    ]);

  # Bootloader.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  networking = {
    hostName = "testagent";
    useNetworkd = true;
  };

  # Enable Acroname USB Smart switch support.
  services.udev.packages = [brainstem];

  environment.systemPackages = [
    inputs.robot-framework.packages.${pkgs.system}.ghaf-robot
    brainstem
    pkgs.minicom
  ];

  # Disable suspend and hibernate - systemd settings
  services.logind.extraConfig = ''
    HandleSuspendKey=ignore
    HandleLidSwitch=ignore
    HandleLidSwitchDocked=ignore
    HandleHibernateKey=ignore
  '';

  # Ensure the system does not automatically suspend or hibernate
  # This is an additional measure to above, can be adjusted as needed
  services.upower.enable = false;

  # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
  # If no user is logged in, the machine will power down after 20 minutes.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # The Jenkins slave service is very barebones
  # it only installs java and sets up jenkins user
  services.jenkinsSlave.enable = true;

  # Gives jenkins user sudo rights without password and serial connection rights
  users.users.jenkins.extraGroups = ["wheel" "dialout" "tty"];

  # Open connection to Jenkins controller as a systemd service
  systemd.services.jenkins-connection = {
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.jdk
      pkgs.git
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.util-linux
      pkgs.nix
      pkgs.zstd
      pkgs.jq
      pkgs.csvkit
      pkgs.sudo
      pkgs.openssh
      pkgs.iputils
      pkgs.netcat
      pkgs.python3
      pkgs.wget
      brainstem
      inputs.robot-framework.packages.${pkgs.system}.ghaf-robot
    ];
    serviceConfig = {
      Type = "simple";
      User = "jenkins";
      WorkingDirectory = "/var/lib/jenkins";
      ExecStart = "${jenkins-connection-script}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    # Give up if it fails more than 5 times in 60 second interval
    startLimitBurst = 5;
    startLimitIntervalSec = 60;
  };

  # configuration file for test hardware devices
  environment.etc."jenkins/test_config.json".text = builtins.toJSON {
    addresses = {
      OrinAGX1 = {
        serial_port = "/dev/ttyACM0";
        device_ip_address = "172.18.16.54";
        socket_ip_address = "172.18.16.74";
        plug_type = "TAPOP100v2";
        location = "testagent";
        usbhub_serial = "0x2954223B";
        threads = 8;
      };
    };
  };
}
