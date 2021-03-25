
import os
import pytest
import subprocess

from util import *

def get_unzipped_image_expression():
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      buildImageUnzipped {
        name = "dedup_image_name";
        tag = "dedup_image_tag";
        fromImage = buildImageUnzipped { name = "bash-layer"; contents = pkgs.bashInteractive; };
        contents = pkgs.bashInteractive;
      }
      """

    return raw.strip().replace("\n", " ")

@pytest.fixture(scope="session")
def image_dir(tmpdir_factory):
    return build_unzipped(get_unzipped_image_expression(),
                          tmpdir_factory.mktemp("unzipped"))


def test_dedup(tmpdir, image_dir):
    validate_image(image_dir, num_layers=2, num_symlink_layers=1)

    unzipped_image_expression = get_unzipped_image_expression()

    tarball = tar_image(unzipped_image_expression, tmpdir)

    # Extract the tarball into a temp folder and make sure it looks good
    examine_folder = tmpdir.join("examine_tarball")
    os.mkdir(examine_folder)
    subprocess.run(["tar", "-xvf", str(tarball), "-C", str(examine_folder)],
                   cwd=tmpdir, check=True)
    validate_image(examine_folder, num_layers=2, num_symlink_layers=0)

    first_tarfile = subprocess.check_output(["bash", "-c", "cat %s/manifest.json | jq -r '.[0].Layers[-2]'" % examine_folder]).decode().strip()
    last_tarfile = subprocess.check_output(["bash", "-c", "cat %s/manifest.json | jq -r '.[0].Layers[-1]'" % examine_folder]).decode().strip()

    assert tar_file_contains(examine_folder.join(first_tarfile), "-bash-interactive-")
    assert not tar_file_contains(examine_folder.join(last_tarfile), "-bash-interactive-")
