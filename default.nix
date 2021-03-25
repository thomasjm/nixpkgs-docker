{
  buildPackages,
  callPackage,
  closureInfo,
  coreutils,
  docker,
  e2fsprogs,
  findutils,
  go,
  jq,
  jshon,
  lib,
  makeWrapper,
  moreutils,
  nix,
  pigz,
  rsync,
  runCommand,
  runtimeShell,
  shadow,
  skopeo,
  stdenv,
  storeDir ? builtins.storeDir,
  substituteAll,
  symlinkJoin,
  utillinux,
  vmTools,
  pkgs,
  writeReferencesToFile,
  writeText,
  writePython3,
  system,  # Note: This is the cross system we're compiling for
}:

# WARNING: this API is unstable and may be subject to backwards-incompatible changes in the future.
let

  mkDbExtraCommand = contents: let
    contentsList = if builtins.isList contents then contents else [ contents ];
  in ''
    echo "Generating the nix database..."
    echo "Warning: only the database of the deepest Nix layer is loaded."
    echo "         If you want to use nix commands in the container, it would"
    echo "         be better to only have one layer that contains a nix store."

    export NIX_REMOTE=local?root=$PWD
    # A user is required by nix
    # https://github.com/NixOS/nix/blob/9348f9291e5d9e4ba3c4347ea1b235640f54fd79/src/libutil/util.cc#L478
    export USER=nobody
    ${buildPackages.nix}/bin/nix-store --load-db < ${closureInfo {rootPaths = contentsList;}}/registration

    mkdir -p nix/var/nix/gcroots/docker/
    for i in ${lib.concatStringsSep " " contentsList}; do
    ln -s $i nix/var/nix/gcroots/docker/$(basename $i)
    done;
  '';

  # Map nixpkgs architecture to Docker notation
  # Reference: https://github.com/docker-library/official-images#architectures-other-than-amd64
  getArch = nixSystem: {
    aarch64-linux = "arm64v8";
    armv7l-linux = "arm32v7";
    x86_64-linux = "amd64";
    powerpc64le-linux = "ppc64le";
    i686-linux = "i386";
  }.${nixSystem} or "Can't map Nix system ${nixSystem} to Docker architecture notation. Please check that your input and your requested build are correct or update the mapping in Nixpkgs.";

in
rec {
  util = (callPackage ./util.nix {});

  examples = import ./examples.nix {
    inherit pkgs buildImage buildImageUnzipped tarImage pullImage buildImageWithNixDb;
    inherit (util) shadowSetup;
  };

  pullImage = (callPackage ./pull-image.nix {}).pullImage;

  buildLayeredImage = (callPackage ./build-layered-image.nix {}).buildLayeredImage;

  exportImage = (callPackage ./export-image.nix {}).exportImage;

  buildImageUnzipped = (callPackage ./build-image.nix {}).buildImage;

  # buildImage is a synonym for buildImageUnzipped + tarImage
  buildImage = args: tarImage { fromImage = buildImageUnzipped args; };

  tarImage = args@{
    fromImage,
    }: runCommand "docker-image.tar.gz" {
      buildInputs = [pigz];
      fromImage = fromImage;
    } ''
      tar -C ${fromImage} --dereference --hard-dereference --xform s:'^./':: -c . | pigz -nT > $out
    '';

  # Build an image and populate its nix database with the provided
  # contents. The main purpose is to be able to use nix commands in
  # the container.
  # Be careful since this doesn't work well with multilayer.
  buildImageWithNixDb = (callPackage ./build-image-with-nix-db.nix {}).buildImageWithNixDb;

  shadowSetup = util.shadowSetup;
}
