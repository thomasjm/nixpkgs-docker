
import os

from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        contents = [pkgs.bashInteractive pkgs.coreutils];
        runAsRoot = ''
          mkdir -p /data;
          echo hello > /data/hello.txt;
          touch /data/chowned; chown 42:24 /data/chowned;
        '';
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")


def test_one_layer_unzipped(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"), tmpdir),
                   num_layers=1, num_symlink_layers=0)

def test_one_layer_zipped(tmpdir):
    image_name = "bash_image"
    image_tag = "bash_tag"

    full_image_name = image_name + ":" + image_tag
    with docker_load(full_image_name, tar_image(get_unzipped_image_expression(image_name, image_tag), tmpdir)):
        # Created file should exist
        assert docker_command(full_image_name, "cat /data/hello.txt") == "hello\n"

        # Chowned file should have the right uid and gid
        assert docker_command(full_image_name, "stat -c \"%u %g\" /data/chowned") == "42 24\n"
