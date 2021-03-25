
mkdir -p $out

eval "$initialCommand"

. "$utilSource"


touch baseFiles
touch layer-list
if [[ -n "$fromImage" ]]; then
  if [[ -d "$fromImage" ]]; then
    cat $fromImage/manifest.json  | jq -r '.[0].Layers | .[]' > layer-list

    echo "Linking base image layers ($fromImage)"
    for baseLayer in $(cat layer-list); do
      if [[ -n "$(dirname $baseLayer)" ]]; then mkdir -p $out/$(dirname $baseLayer); fi
      ln -s $fromImage/$baseLayer $out/$baseLayer

      # Also link the json and VERSION files if present
      jsonFile=$(dirname $baseLayer)/json
      if [ -f "$fromImage/$jsonFile" ]; then ln -s $fromImage/$jsonFile $out/$jsonFile; fi
      versionFile=$(dirname $baseLayer)/VERSION
      if [ -f "$fromImage/$versionFile" ]; then ln -s $fromImage/$versionFile $out/$versionFile; fi
    done

    cp $fromImage/repositories $out/repositories

    cat $fromImage/manifest.json  | jq -r '.[0].Layers | .[]' > layer-list
    fromImageManifest=$(cat $fromImage/manifest.json)
    fromImageConfig=$(cat $fromImage/$(cat $fromImage/manifest.json | jq -r ".[0].Config"))
  elif [[ -f "$fromImage" ]]; then
    echo "Copying base image layers ($fromImage)"
    tar -C $out -xpf "$fromImage"

    cat $out/manifest.json  | jq -r '.[0].Layers | .[]' > layer-list
    fromImageManifest=$(cat $out/manifest.json)
    fromImageConfig=$(cat $out/$(cat $out/manifest.json | jq -r ".[0].Config"))

    # Do not import the base image configuration and manifest
    rm -f image/*.json
  else
    echo "Error: fromImage didn't have expected format (should be either unzipped \"image\" folder or \".tar.gz\", was \"$fromImage\")"
    exit 1
  fi

  chmod a+w $out

  if [[ -z "$fromImageName" ]]; then fromImageName=$(jshon -k < $out/repositories|head -n1); fi
  if [[ -z "$fromImageTag" ]]; then fromImageTag=$(jshon -e $fromImageName -k < $out/repositories | head -n1); fi
  parentID=$(jshon -e $fromImageName -e $fromImageTag -u < $out/repositories)

  echo -n "Gathering base files"
  start_time
  for l in $out/*/layer.tar; do
    ls_tar $l >> baseFiles
  done
  end_time
fi

chmod -R ug+rw $out

mkdir temp
cp ${layer}/* temp/
chmod ug+w temp/*

for dep in $(cat $layerClosure); do
  find $dep >> layerFiles
done

# Record the contents of the tarball with ls_tar. This is so that the files it already contains
# don't get added a second time when we append the closure below. Note that we don't append nix paths
# to the tarball by default anymore in mk-pure-layer.sh, but do this just to be safe. (For example,
# this should product us from adding duplicate /bin symlinks or from files created in a root layer.)
ls_tar temp/layer.tar >> baseFiles

start_time "Finding new files..."
# Get the files in the new layer which were *not* present in
# the old layer, and record them as newFiles.
comm <(sort -n baseFiles | uniq) \
     <(sort -n layerFiles | uniq | grep -v ${layer}) -1 -3 > newFiles
sed -i s:'^/':: newFiles
end_time

start_time "Building layer..."
# Append the new files to the layer.
tar -C / -rpf temp/layer.tar --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --no-recursion --files-from newFiles
end_time

# If we have a parentID, add it to the json metadata.
if [[ -n "$parentID" ]]; then
  cat temp/json | jshon -s "$parentID" -i parent > tmpjson
  mv tmpjson temp/json
fi

start_time "Building metadata..."
# Take the sha256 sum of the generated json and use it as the layer ID.
# Compute the size and add it to the json under the 'Size' field.
layerID=$(sha256sum temp/json | cut -d ' ' -f 1)
size=$(stat --printf="%s" temp/layer.tar)
cat temp/json | jshon -s "$layerID" -i id -n $size -i Size > tmpjson
mv tmpjson temp/json

# Use the temp folder we've been working on to create a new image.
mv temp $out/$layerID

# Add the new layer ID to the beginning of the layer list
(
  # originally this used `sed -i "1i$layerID" layer-list`, but
  # would fail if layer-list was completely empty.
  echo "$layerID/layer.tar"
  cat layer-list
) | sponge layer-list

# Create image json and image manifest
if [[ -n "$fromImage" ]]; then
  imageJson=$fromImageConfig
  baseJsonContents=$(cat $baseJson)

  # Merge the config specified for this layer with the config from the base image.

  # For Env variables, we merge them with those of the base image
  newEnv=$(echo "$baseJsonContents" | jq ".config.Env")
  if [[ -n "$newEnv" && ("$newEnv" != "null") ]]; then
    oldEnv=$(echo "$imageJson" | jq "(.config |= (. // {})) | (.config.Env |= (. // [])) | .config.Env")
    oldEnvWithSpaces=$(echo "$oldEnv" | jq -j '.[]|.," "')

    newEnvWithSpaces=$(echo "$newEnv" | jq -j '.[]|.," "')

    # TODO: sanitize the environment variables for security before putting into a shell command?
    finalEnv=$(env -i $oldEnvWithSpaces $newEnvWithSpaces | head -c -1 | jq --raw-input --slurp 'split("\n")')

    imageJson=$(echo "$imageJson" | jq "(.config |= (. // {})) | (.config.Env |= (. // [])) | (.config.Env |= . + ${finalEnv})")
  fi

  # Volumes likewise get added to existing volumes
  newVolumes=$(echo $baseJsonContents | jq ".config.Volumes")
  if [[ -n "$newVolumes" && ("$newVolumes" != "null") ]]; then
    imageJson=$(echo "$imageJson" | jq ".config.Volumes |= . + ${newVolumes}")
  fi

  # All other values overwrite the ones from the base config
  remainingBaseConfig=$(echo "$baseJsonContents" | jq ".config | del(.Env) | del(.Volumes)")
  if [[ -n "$remainingBaseConfig" && ("$remainingBaseConfig" != "null")]]; then
    imageJson=$(echo "$imageJson" | jq ".config |= . + ${remainingBaseConfig}")
  fi

  manifestJson=$(echo "$fromImageManifest" | jq ".[0] |= . + {\"RepoTags\":[\"$imageName:$imageTag\"]}")
else
  imageJson=$(cat ${baseJson} | jq ". + {\"rootfs\": {\"diff_ids\": [], \"type\": \"layers\"}}")
  manifestJson=$(jq -n "[{\"RepoTags\":[\"$imageName:$imageTag\"]}]")
fi
end_time

# Add a history item and new layer checksum to the image json
imageJson=$(echo "$imageJson" | jq ".history |= . + [{\"created\": \"$(jq -r .created ${baseJson})\", \"created_by\": \"$imageName:$imageTag\"}]")
start_time "Taking sha256sum of layer $out/$layerID/layer.tar..."
# stat $out/$layerID/layer.tar
newLayerChecksum=$(sha256sum $out/$layerID/layer.tar | cut -d ' ' -f1)
imageJson=$(echo "$imageJson" | jq ".rootfs.diff_ids |= . + [\"sha256:$newLayerChecksum\"]")
end_time

# Add the new layer to the image manifest
manifestJson=$(echo "$manifestJson" | jq ".[0].Layers |= . + [\"$layerID/layer.tar\"]")

# Compute the checksum of the config and save it, and also put it in the manifest
imageJsonChecksum=$(echo "$imageJson" | sha256sum | cut -d ' ' -f1)
echo "$imageJson" > "$out/$imageJsonChecksum.json"
manifestJson=$(echo "$manifestJson" | jq ".[0].Config = \"$imageJsonChecksum.json\"")
echo "$manifestJson" > $out/manifest.json

# Store the json under the name image/repositories.
jshon -n object \
      -n object -s "$layerID" -i "$imageTag" \
      -i "$imageName" > $out/repositories

# Make the image read-only.
chmod -R 744 $out

echo "Finished."
