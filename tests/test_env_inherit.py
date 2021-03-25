
import subprocess

from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        fromImage = buildImageUnzipped { name = "bash-layer"; contents = pkgs.bashInteractive; config = { Env = ["FOO=BAR"]; }; };
        config = { Env = ["BAR=BAZ"]; };
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

def test_valid(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"), tmpdir),
                   num_layers=2, num_symlink_layers=1)

def test_docker_load(tmpdir):
    image_name = "bash_image"
    image_tag = "bash_tag"
    unzipped_image_expression = get_unzipped_image_expression(image_name, image_tag)

    full_image_name = image_name + ":" + image_tag
    with docker_load(full_image_name, tar_image(unzipped_image_expression, tmpdir)):
        # Test both environment variables are set
        assert docker_command(full_image_name, "echo $FOO") == "BAR\n"
        assert docker_command(full_image_name, "echo $BAR") == "BAZ\n"
