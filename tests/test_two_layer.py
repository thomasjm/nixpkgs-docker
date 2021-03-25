
import os
import pytest
import subprocess

from util import *

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "%s";
        tag = "%s";
        fromImage = buildImageUnzipped { name = "bash-layer"; contents = pkgs.bashInteractive; };
        contents = pkgs.file;
      }
      """ % (name, tag)

    return raw.strip().replace("\n", " ")

@pytest.fixture(scope="session")
def image_dir(tmpdir_factory):
    return build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"),
                          tmpdir_factory.mktemp("unzipped"))

def test_two_layer_unzipped_valid(image_dir):
    validate_image(image_dir, num_layers=2, num_symlink_layers=1)

def test_has_base_image_as_nix_dependency(image_dir):
    assert "bash-layer" in subprocess.check_output(["nix-store", "--query", "--tree", image_dir]).decode()

def test_two_layer_zipped(tmpdir):
    image_name = "two_layer"
    tag_name = "two_layer_tag"
    unzipped_image_expression = get_unzipped_image_expression(image_name, tag_name)

    tarball = tar_image(unzipped_image_expression, tmpdir)

    # Extract the tarball into a temp folder and make sure it looks good
    examine_folder = tmpdir.join("examine_tarball")
    os.mkdir(examine_folder)
    subprocess.run(["tar", "-xvf", str(tarball), "-C", str(examine_folder)],
                   cwd=tmpdir, check=True)
    validate_image(examine_folder, num_layers=2, num_symlink_layers=0)

    full_image_name = image_name + ":" + tag_name
    with docker_load(full_image_name, tarball):
        assert docker_command(full_image_name, "echo hi > some_file; file some_file") == "some_file: ASCII text\n"
