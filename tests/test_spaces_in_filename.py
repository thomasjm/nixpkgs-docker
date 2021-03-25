
import docker
import os
import subprocess

from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        contents = [pkgs.bashInteractive pkgs.coreutils-full
                    (runCommand "output-with-filename-spaces" {} "mkdir -p $out/bin; echo contents >> $out/bin/spaced\\\\ filename.txt; chmod u+x $out/bin/spaced\\\\ filename.txt")];
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

def test_valid(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"), tmpdir),
                   num_layers=1, num_symlink_layers=0)

def test_docker_load(tmpdir):
    image_name = "spaces_in_filename_image"
    image_tag = "spaces_in_filename_tag"
    unzipped_image_expression = get_unzipped_image_expression(image_name, image_tag)

    tarball = tar_image(unzipped_image_expression, tmpdir)
    full_image_name = image_name + ":" + image_tag
    with docker_load(full_image_name, tarball):
        assert docker_command(full_image_name, "cat /bin/spaced\ filename.txt") == "contents\n"
