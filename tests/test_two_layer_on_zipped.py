
import pytest

from util import *

def get_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        fromImage = buildImage { name = "bash-layer"; contents = pkgs.bashInteractive; };
        contents = pkgs.file;
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

@pytest.fixture(scope="session")
def image_dir(tmpdir_factory):
    return build_unzipped(get_image_expression("some_image_name", "some_tag"),
                          tmpdir_factory.mktemp("unzipped"))

def test_valid(image_dir):
    validate_image(image_dir, num_layers=2, num_symlink_layers=0)
