# llama.cpp with GGML_RPC=ON. Same source on every node, compiled per arch.
{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  src,
  vulkanSupport ? stdenv.hostPlatform.isLinux,
  vulkan-headers ? null,
  vulkan-loader ? null,
  spirv-headers ? null,
  shaderc ? null,
  metalSupport ? stdenv.hostPlatform.isDarwin,
}:

stdenv.mkDerivation {
  pname = "llama-cpp-rpc";
  version = "flake-pinned";

  inherit src;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
  ] ++ lib.optionals vulkanSupport [ shaderc ];

  buildInputs = lib.optionals vulkanSupport [
    vulkan-headers
    vulkan-loader
    spirv-headers
  ];

  cmakeFlags =
    [
      "-DGGML_RPC=ON"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DLLAMA_BUILD_TESTS=OFF"
      "-DLLAMA_BUILD_EXAMPLES=ON"
      "-DGGML_NATIVE=OFF"
      "-DGGML_AVX2=ON"
    ]
    ++ lib.optionals vulkanSupport [
      "-DGGML_VULKAN=ON"
    ]
    ++ lib.optionals (!vulkanSupport) [
      "-DGGML_VULKAN=OFF"
    ];

  buildTargets = [
    "llama-server"
    "llama-bench"
    "rpc-server"
    "ggml-rpc-server"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp bin/llama-server bin/llama-bench $out/bin/
    if [ -f bin/rpc-server ]; then
      cp bin/rpc-server $out/bin/rpc-server
    elif [ -f bin/ggml-rpc-server ]; then
      cp bin/ggml-rpc-server $out/bin/rpc-server
      ln -s rpc-server $out/bin/ggml-rpc-server
    else
      echo "no rpc server binary found:"; ls -la bin/ | grep -i rpc || true
      exit 1
    fi
    echo "${src.rev or "unknown"}" > $out/share-llama-rev 2>/dev/null || true
    cp $out/share-llama-rev $out/bin/.llama-rev 2>/dev/null || echo unknown > $out/bin/.llama-rev
    runHook postInstall
  '';

  meta = with lib; {
    description = "llama.cpp with GGML_RPC=ON for grid-think (pipeline-parallel over TCP)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
    ];
  };
}
