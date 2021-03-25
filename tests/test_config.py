
import subprocess

from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        contents = [pkgs.bashInteractive pkgs.coreutils];
        config = {
          Cmd = [ "ls" "-lh" "/data" ];
          WorkingDir = "/data";
          Env = ["FOO=BAR"];
          Volumes = {
            "/data" = {};
          };
        };
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

image_name = "config_image_name"
image_tag = "config_image_tag"

def test_one_layer_unzipped(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression(image_name, image_tag), tmpdir),
                   num_layers=1, num_symlink_layers=0)

def test_docker_load(tmpdir):
    unzipped_image_expression = get_unzipped_image_expression(image_name, image_tag)

    full_image_name = image_name + ":" + image_tag

    with docker_load(full_image_name, tar_image(unzipped_image_expression, tmpdir)):
        # Test working dir is set correctly
        assert docker_command(full_image_name, "pwd") == "/data\n"

        # Test environment variable is set
        assert docker_command(full_image_name, "echo $FOO") == "BAR\n"

        # Test default command is run
        assert subprocess.check_output(["docker", "run", "-i", "--rm", full_image_name]).decode() == "total 0\n"
