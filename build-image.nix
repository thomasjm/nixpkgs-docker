{
  callPackage,
  coreutils,
  findutils,
  jshon,
  jq,
  lib,
  pkgs,
  pigz,
  bc,
  runCommand,
  rsync,
  storeDir ? builtins.storeDir,
  writeReferencesToFile,
  writeText
}:

rec {
  util = (callPackage ./util.nix {});
  tarsum = util.tarsum;

  runWithOverlay = (callPackage ./run-with-overlay.nix {}).runWithOverlay;

  # 1. extract the base image
  # 2. create the layer
  # 3. add layer deps to the layer itself, diffing with the base image
  # 4. compute the layer id
  # 5. put the layer in the image
  # 6. repack the image
  buildImage = args@{
    # Image name.
    name,
    # Image tag, when null then the nix output hash will be used.
    tag ? null,
    # Parent image, to append to.
    fromImage ? null,
    # Name of the parent image; will be read from the image otherwise.
    fromImageName ? null,
    # Tag of the parent image; will be read from the image otherwise.
    fromImageTag ? null,
    # Files to put on the image (a nix store path or list of paths).
    contents ? null,
    # When copying the contents into the image, preserve symlinks to
    # directories (see `rsync -K`).  Otherwise, transform those symlinks
    # into directories.
    keepContentsDirlinks ? false,
    # Docker config; e.g. what command to run on the container.
    config ? null,
    # Optional bash script to run on the files prior to fixturizing the layer.
    extraCommands ? "",
    # UID and GID to apply to every file in the layer
    uid ? 0, gid ? 0,
    # Optional bash script to run as root on the image when provisioning.
    runAsRoot ? null,
    # Size of the virtual machine disk to provision when building the image.
    diskSize ? 1024,
    # Time of creation of the image.
    created ? "1970-01-01T00:00:01Z",
    # Folder in the image under which to put bin symlinks.
    # This is configurable because some base images (such as ubuntu:20.04
    # at time of writing) make /bin a symlink to /usr/bin, so turning it into
    # a folder to contain nix bin symlinks blows it away.
    binFolder ? "bin",
    # Extra build inputs (to be used in extraCommands or runAsRoot)
    extraBuildInputs ? []
  }:

    let
      baseName = baseNameOf name;

      # Create a JSON blob of the configuration. Set the date to unix zero.
      baseJson = let
          pure = writeText "${baseName}-config.json" (builtins.toJSON {
            inherit created config;
            architecture = "amd64";
            os = "linux";
          });
          impure = runCommand "${baseName}-config.json"
            { buildInputs = [ jq ]; }
            ''
               jq ".created = \"$(TZ=utc date --iso-8601="seconds")\"" ${pure} > $out
            '';
        in if created == "now" then impure else pure;

      layer =
        if runAsRoot == null
        then mkPureLayer {
          name = baseName;
          inherit baseJson contents extraCommands extraBuildInputs uid gid binFolder;
        } else mkRootLayer {
          name = baseName;
          inherit baseJson fromImage fromImageName fromImageTag
                  contents keepContentsDirlinks runAsRoot diskSize
                  extraCommands binFolder;
        };
      result = runCommand "docker-image-${baseName}" {
        buildInputs = [ jshon pigz coreutils findutils jq pkgs.moreutils bc ] ++ extraBuildInputs;
        # Image name and tag must be lowercase
        imageName = lib.toLower name;
        imageTag = if tag == null then "" else lib.toLower tag;
        inherit fromImage baseJson layer;
        layerClosure = writeReferencesToFile layer;
        passthru.buildArgs = args;
        passthru.layer = layer;
        initialCommand = lib.optionalString (tag == null) ''
          outName="$(basename "$out")"
          outHash=$(echo "$outName" | cut -d - -f 1)

          imageTag=$outHash
        '';
        utilSource = ./util.sh;
        script = ./build-image.sh;
      } "source $script";

    in
    result;

  # Create a "layer" (set of files).
  mkPureLayer = {
    # Name of the layer
    name,
    # JSON containing configuration and metadata for this layer.
    baseJson,
    # Files to add to the layer.
    contents ? null,
    # Additional commands to run on the layer before it is tar'd up.
    extraCommands ? "",
    # uid and gid to apply to all files in the layer
    uid ? 0, gid ? 0,
    # folder in the image under which to put bin symlinks
    binFolder ? "bin",
    # Extra build inputs
    extraBuildInputs ? []
  }:
    runCommand "docker-layer-${name}" {
      inherit baseJson contents extraCommands uid gid;
      buildInputs = [ jshon rsync tarsum ] ++ extraBuildInputs;
      script = ./mk-pure-layer.sh;
    } ''export BIN_FOLDER="${binFolder}"; source $script'';

  # Make a "root" layer; required if we need to execute commands as a
  # privileged user on the image. The commands themselves will be
  # performed in a virtual machine sandbox.
  mkRootLayer = {
    # Name of the image.
    name,
    # Script to run as root. Bash.
    runAsRoot,
    # Files to add to the layer. If null, an empty layer will be created.
    contents ? null,
    # When copying the contents into the image, preserve symlinks to
    # directories (see `rsync -K`).  Otherwise, transform those symlinks
    # into directories.
    keepContentsDirlinks ? false,
    # JSON containing configuration and metadata for this layer.
    baseJson,
    # Existing image onto which to append the new layer.
    fromImage ? null,
    # Name of the image we're appending onto.
    fromImageName ? null,
    # Tag of the image we're appending onto.
    fromImageTag ? null,
    # How much disk to allocate for the temporary virtual machine.
    diskSize ? 1024,
    # Commands (bash) to run on the layer; these do not require sudo.
    extraCommands ? "",
    # folder in the image under which to put bin symlinks
    binFolder ? "bin",
    # Extra build inputs
    extraBuildInputs ? [] # TODO
  }:
    # Generate an executable script from the `runAsRoot` text.
    let
      runAsRootScript = util.shellScript "run-as-root.sh" runAsRoot;
      extraCommandsScript = util.shellScript "extra-commands.sh" extraCommands;
    in runWithOverlay {
      name = "docker-layer-${name}";

      inherit fromImage fromImageName fromImageTag diskSize;

      preMount = lib.optionalString (contents != null && contents != []) ''
        echo "Adding contents..."
        for item in ${toString contents}; do
          echo "Adding $item..."
          rsync -a${if keepContentsDirlinks then "K" else "k"} --chown=0:0 $item/ layer/
        done

        chmod ug+w layer
      '';

      postMount = ''
        mkdir -p mnt/{dev,proc,sys} mnt${storeDir}

        # Mount /dev, /sys and the nix store as shared folders.
        mount --rbind /dev mnt/dev
        mount --rbind /sys mnt/sys
        mount --rbind ${storeDir} mnt${storeDir}

        # Execute the run as root script. See 'man unshare' for
        # details on what's going on here; basically this command
        # means that the runAsRootScript will be executed in a nearly
        # completely isolated environment.
        unshare -imnpuf --mount-proc chroot mnt ${runAsRootScript}

        # Unmount directories and remove them.
        umount -R mnt/dev mnt/sys mnt${storeDir}
        rmdir --ignore-fail-on-non-empty \
          mnt/dev mnt/proc mnt/sys mnt${storeDir} \
          mnt$(dirname ${storeDir})
      '';

      postUmount = ''
        (cd layer; ${extraCommandsScript})

        echo "Packing root layer..."
        mkdir $out
        tar -C layer --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" -cf $out/layer.tar .

        # Compute the tar checksum and add it to the output json.
        echo "Computing root layer checksum..."
        tarhash=$(${tarsum}/bin/tarsum < $out/layer.tar)
        cat ${baseJson} | jshon -s "$tarhash" -i checksum > $out/json
        # Indicate to docker that we're using schema version 1.0.
        echo -n "1.0" > $out/VERSION

        echo "Finished building root layer '${name}'"
      '';
    };
}
