{
  callPackage,
  lib,
  nix,
  closureInfo
}:

# WARNING: this API is unstable and may be subject to backwards-incompatible changes in the future.

rec {
  util = (callPackage ./util.nix {});

  buildImage = (callPackage ./build-image.nix {}).buildImage;

  # Build an image and populate its nix database with the provided
  # contents. The main purpose is to be able to use nix commands in
  # the container.
  # Be careful since this doesn't work well with multilayer.
  buildImageWithNixDb = args@{ contents ? null, extraCommands ? "", ... }:
    let contentsList = if builtins.isList contents then contents else [ contents ];
    in buildImage (args // {
      extraCommands = ''
        echo "Generating the nix database..."
        echo "Warning: only the database of the deepest Nix layer is loaded."
        echo "         If you want to use nix commands in the container, it would"
        echo "         be better to only have one layer that contains a nix store."

        export NIX_REMOTE=local?root=$PWD
        ${nix}/bin/nix-store --load-db < ${closureInfo {rootPaths = contentsList;}}/registration

        mkdir -p nix/var/nix/gcroots/docker/
        for i in ${lib.concatStringsSep " " contentsList}; do
          ln -s $i nix/var/nix/gcroots/docker/$(basename $i)
        done;
      '' + extraCommands;
    });
}
