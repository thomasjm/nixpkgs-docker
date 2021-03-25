{
  lib,
  pkgs,
  runCommand,
  stdenv,
  curl
}:

rec {
  pullImage = let
    fixName = name: builtins.replaceStrings ["/" ":"] ["-" "-"] name;
  in
    { imageName
      # To find the digest of an image, you can use skopeo:
      # see doc/functions.xml
    , imageDigest
    , sha256
    , os ? "linux"
    , arch ? "amd64"
      # This used to set a tag to the pulled image
    , finalImageTag ? "latest"
    , name ? fixName "docker-image-${imageName}-${finalImageTag}"
    }:

    runCommand name {
      inherit imageName imageDigest;
      imageTag = finalImageTag;
      impureEnvVars = pkgs.stdenv.lib.fetchers.proxyImpureEnvVars;
      # impureEnvVars = pkgs.stdenv.lib.fetchers.proxyImpureEnvVars ++ [
      #   "GIT_PROXY_COMMAND" "SOCKS_SERVER"
      # ];
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = sha256;

      buildInputs = [curl];

      nativeBuildInputs = lib.singleton (pkgs.skopeo);
      SSL_CERT_FILE = "${pkgs.cacert.out}/etc/ssl/certs/ca-bundle.crt";

      sourceURL = "docker://${imageName}@${imageDigest}";
      destNameTag = "${imageName}:${finalImageTag}";
    } ''
      mkdir -p $out
      skopeo --override-os ${os} --override-arch ${arch} copy --dest-compress=false "$sourceURL" "docker-archive://$out/image.tar:$destNameTag"

      tar -C $out -xvf $out/image.tar
      rm $out/image.tar
    '';
}
