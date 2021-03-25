{
  callPackage
}:

rec {
  util = (callPackage ./util.nix {});

  runWithOverlay = (callPackage ./run-with-overlay.nix {}).runWithOverlay;

  exportImage = { name ? fromImage.name, fromImage, fromImageName ? null, fromImageTag ? null, diskSize ? 1024 }:
    runWithOverlay {
      inherit name fromImage fromImageName fromImageTag diskSize;

      postMount = ''
        echo "Packing raw image..."
        tar -C mnt --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" -cf $out .
      '';
    };
}
