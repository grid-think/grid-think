{
  description = "grid-think - run LLMs across a grid of ordinary machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Pinned so every node compiles the same source. RPC breaks across revs.
    llama-cpp.url = "github:ggml-org/llama.cpp";
    llama-cpp.flake = false;
  };

  outputs =
    { self, nixpkgs, llama-cpp }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      gridSshKeys =
        let
          f = ./nixos/authorized_keys;
        in
        if builtins.pathExists f then
          builtins.filter (l: l != "" && !(nixpkgs.lib.hasPrefix "#" l)) (
            nixpkgs.lib.splitString "\n" (
              nixpkgs.lib.removeSuffix "\n" (builtins.readFile f)
            )
          )
        else
          [ ];
      mkWorkerIso = targetSystem: (
        nixpkgs.lib.nixosSystem {
          system = targetSystem;
          specialArgs = {
            gridLlamaRpc = self.packages.${targetSystem}.llama-cpp-rpc;
            gridAgent = self.packages.${targetSystem}.grid-agent;
            inherit gridSshKeys;
          };
          modules = [ self.nixosModules.worker ];
        }
      ).config.system.build.isoImage;
    in
    {
      nixosModules.worker = ./nixos/worker.nix;

      packages = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          llama-cpp-rpc = pkgs.callPackage ./nix/llama-cpp-rpc.nix {
            src = llama-cpp;
          };
          llama-cpp-rpc-cpu = pkgs.callPackage ./nix/llama-cpp-rpc.nix {
            src = llama-cpp;
            vulkanSupport = false;
          };
          grid-python = pkgs.python3.withPackages (_ps: [ ]);
          grid-agent = pkgs.writeShellApplication {
            name = "grid-agent";
            runtimeInputs = [
              grid-python
              llama-cpp-rpc
            ];
            text = ''
              export PYTHONPATH="${./.}''${PYTHONPATH:+:$PYTHONPATH}"
              exec python3 "${./grid/agent.py}" "$@"
            '';
          };
          grid-control = pkgs.writeShellApplication {
            name = "grid-control";
            runtimeInputs = [ grid-python ];
            text = ''
              export PYTHONPATH="${./.}''${PYTHONPATH:+:$PYTHONPATH}"
              exec python3 "${./grid/control.py}" "$@"
            '';
          };
        in
        {
          inherit llama-cpp-rpc llama-cpp-rpc-cpu grid-agent grid-control;
          default = grid-control;
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          worker-iso = mkWorkerIso system;
        }
      );

      devShells = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            name = "grid-think";
            packages = with pkgs; [
              python3
              cmake
              ninja
              ccache
              pkg-config
              git
              jq
              iperf3
              vulkan-loader
              qemu
              cdrtools
              openssh
              self.packages.${system}.llama-cpp-rpc
              self.packages.${system}.grid-agent
              self.packages.${system}.grid-control
            ];
            shellHook = ''
              echo "grid-think | $(uname -m) | llama.cpp rev: $(cat ${llama-cpp}/.git-rev 2>/dev/null || echo flake.lock-pinned)"
              echo "try: grid-control --help | grid-agent --help | python3 -m pytest tests/ -q"
              export GRID_LLAMA_REV="${llama-cpp.shortRev or "flake.lock"}"
              export CMAKE_GENERATOR="Ninja"
            '';
          };
        }
      );

      apps = forEachSystem (
        system:
        let
          getExe = pkg: "${self.packages.${system}.${pkg}}/bin/${pkg}";
        in
        {
          grid-agent = {
            type = "app";
            program = getExe "grid-agent";
          };
          grid-control = {
            type = "app";
            program = getExe "grid-control";
          };
        }
      );

      checks = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          planner-tests = pkgs.runCommand "planner-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            cp -r ${./.} src
            chmod -R +w src
            python3 -m py_compile src/grid/*.py
            python3 src/tests/test_planner.py
            touch $out
          '';
        }
      );
    };
}
