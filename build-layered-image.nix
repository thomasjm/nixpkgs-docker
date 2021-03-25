{
  callPackage,
  symlinkJoin,
  findutils,
  jshon,
  jq,
  lib,
  pigz,
  runCommand,
  rsync,
  referencesByPopularity,
  writeText,
  substituteAll,
  runtimeShell
}:

# WARNING: this API is unstable and may be subject to backwards-incompatible changes in the future.

rec {
  util = (callPackage ./util.nix {});
  tarsum = util.tarsum;

  buildLayeredImage = {
    # Image Name
    name,
    # Image tag, the Nix's output hash will be used if null
    tag ? null,
    # Files to put on the image (a nix store path or list of paths).
    contents ? [],
    # Docker config; e.g. what command to run on the container.
    config ? {},
    # Time of creation of the image. Passing "now" will make the
    # created date be the time of building.
    created ? "1970-01-01T00:00:01Z",
    # Optional bash script to run on the files prior to fixturizing the layer.
    extraCommands ? "", uid ? 0, gid ? 0,
    # Docker's lowest maximum layer limit is 42-layers for an old
    # version of the AUFS graph driver. We pick 24 to ensure there is
    # plenty of room for extension. I believe the actual maximum is
    # 128.
    maxLayers ? 24
  }:
    let
      baseName = baseNameOf name;
      contentsEnv = symlinkJoin { name = "bulk-layers"; paths = (if builtins.isList contents then contents else [ contents ]); };

      configJson = let
          pure = writeText "${baseName}-config.json" (builtins.toJSON {
            inherit created config;
            architecture = "amd64";
            os = "linux";
          });
          impure = runCommand "${baseName}-standard-dynamic-date.json"
            { buildInputs = [ jq ]; }
            ''
               jq ".created = \"$(TZ=utc date --iso-8601="seconds")\"" ${pure} > $out
            '';
        in if created == "now" then impure else pure;

      bulkLayers = mkManyPureLayers {
          name = baseName;
          closure = writeText "closure" "${contentsEnv} ${configJson}";
          # One layer will be taken up by the customisationLayer, so
          # take up one less.
          maxLayers = maxLayers - 1;
          inherit configJson;
        };
      customisationLayer = mkCustomisationLayer {
          name = baseName;
          contents = contentsEnv;
          baseJson = configJson;
          inherit uid gid extraCommands;
        };
      result = runCommand "docker-image-${baseName}.tar.gz" {
        buildInputs = [ jshon pigz coreutils findutils jq ];
        # Image name and tag must be lowercase
        imageName = lib.toLower name;
        baseJson = configJson;
        passthru.imageTag =
          if tag == null
          then lib.head (lib.splitString "-" (lib.last (lib.splitString "/" result)))
          else lib.toLower tag;
      } ''
        ${if (tag == null) then ''
          outName="$(basename "$out")"
          outHash=$(echo "$outName" | cut -d - -f 1)

          imageTag=$outHash
        '' else ''
          imageTag="${tag}"
        ''}

        find ${bulkLayers} -mindepth 1 -maxdepth 1 | sort -t/ -k5 -n > layer-list
        echo ${customisationLayer} >> layer-list

        mkdir image
        imageJson=$(cat ${configJson} | jq ". + {\"rootfs\": {\"diff_ids\": [], \"type\": \"layers\"}}")
        manifestJson=$(jq -n "[{\"RepoTags\":[\"$imageName:$imageTag\"]}]")
        for layer in $(cat layer-list); do
          layerChecksum=$(sha256sum $layer/layer.tar | cut -d ' ' -f1)
          layerID=$(sha256sum "$layer/json" | cut -d ' ' -f 1)
          ln -s "$layer" "./image/$layerID"

          manifestJson=$(echo "$manifestJson" | jq ".[0].Layers |= [\"$layerID/layer.tar\"] + .")
          imageJson=$(echo "$imageJson" | jq ".history |= [{\"created\": \"$(jq -r .created ${configJson})\"}] + .")
          imageJson=$(echo "$imageJson" | jq ".rootfs.diff_ids |= [\"sha256:$layerChecksum\"] + .")
        done
        imageJsonChecksum=$(echo "$imageJson" | sha256sum | cut -d ' ' -f1)
        echo "$imageJson" > "image/$imageJsonChecksum.json"
        manifestJson=$(echo "$manifestJson" | jq ".[0].Config = \"$imageJsonChecksum.json\"")
        echo "$manifestJson" > image/manifest.json

        jshon -n object \
          -n object -s "$layerID" -i "$imageTag" \
          -i "$imageName" > image/repositories

        echo "Cooking the image..."
        tar -C image --dereference --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0  --mode=a-w --xform s:'^./':: -c . | pigz -nT > $out

        echo "Finished."
      '';

    in
    result;

  # Create $maxLayers worth of Docker Layers, one layer per store path
  # unless there are more paths than $maxLayers. In that case, create
  # $maxLayers-1 for the most popular layers, and smush the remainaing
  # store paths in to one final layer.
  mkManyPureLayers = {
    name,
    # Files to add to the layer.
    closure,
    configJson,
    # Docker has a 42-layer maximum, we pick 24 to ensure there is plenty
    # of room for extension
    maxLayers ? 24
  }:
    let
      storePathToLayer = substituteAll
      { shell = runtimeShell;
        isExecutable = true;
        src = ./store-path-to-layer.sh;
      };
    in
    runCommand "${name}-granular-docker-layers" {
      inherit maxLayers;
      paths = referencesByPopularity closure;
      buildInputs = [ jshon rsync tarsum ];
      enableParallelBuilding = true;
    }
    ''
      # Delete impurities for store path layers, so they don't get
      # shared and taint other projects.
      cat ${configJson} \
        | jshon -d config \
        | jshon -s "1970-01-01T00:00:01Z" -i created > generic.json

      # WARNING!
      # The following code is fiddly w.r.t. ensuring every layer is
      # created, and that no paths are missed. If you change the
      # following head and tail call lines, double-check that your
      # code behaves properly when the number of layers equals:
      #      maxLayers-1, maxLayers, and maxLayers+1
      head -n $((maxLayers - 1)) $paths | cat -n | xargs -P$NIX_BUILD_CORES -n2 ${storePathToLayer}
      if [ $(cat $paths | wc -l) -ge $maxLayers ]; then
        tail -n+$maxLayers $paths | xargs ${storePathToLayer} $maxLayers
      fi

      echo "Finished building layer '$name'"

      mv ./layers $out
    '';

  # Create a "Customisation" layer which adds symlinks at the root of
  # the image to the root paths of the closure. Also add the config
  # data like what command to run and the environment to run it in.
  mkCustomisationLayer = {
    name,
    # Files to add to the layer.
    contents,
    baseJson,
    extraCommands,
    uid ? 0, gid ? 0,
  }:
    runCommand "${name}-customisation-layer" {
      buildInputs = [ jshon rsync tarsum ];
      inherit extraCommands;
    }
    ''
      cp -r ${contents}/ ./layer

      if [[ -n $extraCommands ]]; then
        chmod ug+w layer
        (cd layer; eval "$extraCommands")
      fi

      # Tar up the layer and throw it into 'layer.tar'.
      echo "Packing layer..."
      mkdir $out
      tar --transform='s|^\./||' -C layer --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=${toString uid} --group=${toString gid} -cf $out/layer.tar .

      # Compute a checksum of the tarball.
      echo "Computing layer checksum..."
      tarhash=$(tarsum < $out/layer.tar)

      # Add a 'checksum' field to the JSON, with the value set to the
      # checksum of the tarball.
      cat ${baseJson} | jshon -s "$tarhash" -i checksum > $out/json

      # Indicate to docker that we're using schema version 1.0.
      echo -n "1.0" > $out/VERSION
    '';
}
