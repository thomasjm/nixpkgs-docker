
from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        contents = pkgs.bashInteractive;
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

def test_valid(tmpdir):
    validate_image(build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"), tmpdir),
                   num_layers=1, num_symlink_layers=0)

def test_docker_load(tmpdir):
    image_name = "bash_image"
    image_tag = "bash_tag"
    unzipped_image_expression = get_unzipped_image_expression(image_name, image_tag)

    tarball = tar_image(unzipped_image_expression, tmpdir)
    full_image_name = image_name + ":" + image_tag
    with docker_load(full_image_name, tarball):
        assert docker_command(full_image_name, "echo -n hi") == "hi"
