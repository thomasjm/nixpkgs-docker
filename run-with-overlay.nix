{
  callPackage,
  symlinkJoin,
  coreutils,
  docker,
  e2fsprogs,
  findutils,
  go,
  jshon,
  jq,
  lib,
  pkgs,
  pigz,
  nix,
  runCommand,
  rsync,
  shadow,
  stdenv,
  storeDir ? builtins.storeDir,
  utillinux,
  vmTools,
  writeReferencesToFile,
  referencesByPopularity,
  writeText,
  closureInfo,
  substituteAll,
  runtimeShell
}:

rec {
  # Run commands in a virtual machine.
  runWithOverlay = {
    name,
    fromImage ? null,
    fromImageName ? null,
    fromImageTag ? null,
    diskSize ? 1024,
    preMount ? "",
    postMount ? "",
    postUmount ? ""
  }:
    vmTools.runInLinuxVM (
      runCommand name {
        preVM = vmTools.createEmptyImage {
          size = diskSize;
          fullName = "docker-run-disk";
        };
        inherit fromImage fromImageName fromImageTag;

        buildInputs = [ utillinux e2fsprogs jshon rsync jq ];
      } ''
      rm -rf $out

      mkdir disk
      mkfs /dev/${vmTools.hd}
      mount /dev/${vmTools.hd} disk
      cd disk

      if [[ -n "$fromImage" ]]; then
        echo "Unpacking base image..."
        mkdir image
        tar -C image -xpf "$fromImage"

        # If the image name isn't set, read it from the image repository json.
        if [[ -z "$fromImageName" ]]; then
          fromImageName=$(jshon -k < image/repositories | head -n 1)
          echo "From-image name wasn't set. Read $fromImageName."
        fi

        # If the tag isn't set, use the name as an index into the json
        # and read the first key found.
        if [[ -z "$fromImageTag" ]]; then
          fromImageTag=$(jshon -e $fromImageName -k < image/repositories | head -n1)
          echo "From-image tag wasn't set. Read $fromImageTag."
        fi

        # Use the name and tag to get the parent ID field.
        parentID=$(jshon -e $fromImageName -e $fromImageTag -u < image/repositories)

        cat ./image/manifest.json  | jq -r '.[0].Layers | .[]' > layer-list
      else
        touch layer-list
      fi

      # Unpack all of the parent layers into the image.
      lowerdir=""
      extractionID=0
      for layerTar in $(tac layer-list); do
        echo "Unpacking layer $layerTar"
        extractionID=$((extractionID + 1))

        mkdir -p image/$extractionID/layer
        tar -C image/$extractionID/layer -xpf image/$layerTar
        rm image/$layerTar

        find image/$extractionID/layer -name ".wh.*" -exec bash -c 'name="$(basename {}|sed "s/^.wh.//")"; mknod "$(dirname {})/$name" c 0 0; rm {}' \;

        # Get the next lower directory and continue the loop.
        lowerdir=$lowerdir''${lowerdir:+:}image/$extractionID/layer
      done

      mkdir work
      mkdir layer
      mkdir mnt

      ${lib.optionalString (preMount != "") ''
        # Execute pre-mount steps
        echo "Executing pre-mount steps..."
        ${preMount}
      ''}

      if [ -n "$lowerdir" ]; then
        mount -t overlay overlay -olowerdir=$lowerdir,workdir=work,upperdir=layer mnt
      else
        mount --bind layer mnt
      fi

      ${lib.optionalString (postMount != "") ''
        # Execute post-mount steps
        echo "Executing post-mount steps..."
        ${postMount}
      ''}

      umount mnt

      (
        cd layer
        cmd='name="$(basename {})"; touch "$(dirname {})/.wh.$name"; rm "{}"'
        find . -type c -exec bash -c "$cmd" \;
      )

      ${postUmount}
      '');
}
