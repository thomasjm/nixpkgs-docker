
from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        contents = [pkgs.bashInteractive pkgs.coreutils];
        extraCommands = "
          mkdir -p ./home/user;
          echo bar > ./home/user/foo;
          chown 1000:1000 ./home/user/foo;
        ";
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

IMAGE_NAME = "extra_commands_image"
IMAGE_TAG = "extra_commands_tag"

def test_valid(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression(IMAGE_NAME, IMAGE_TAG), tmpdir),
                   num_layers=1, num_symlink_layers=0)

def test_docker_load(tmpdir):
    print("tmpdir", tmpdir)
    unzipped_image_expression = get_unzipped_image_expression(IMAGE_NAME, IMAGE_TAG)

    full_image_name = IMAGE_NAME + ":" + IMAGE_TAG

    with docker_load(full_image_name, tar_image(unzipped_image_expression, tmpdir)):
        # Created file should exist
        assert docker_command(full_image_name, "cat /home/user/foo") == "bar\n"

        # Created file should have the permissions we chowned
        assert docker_command(full_image_name, "stat -c \"%u %g\" /home/user/foo") == "1000 1000\n"
