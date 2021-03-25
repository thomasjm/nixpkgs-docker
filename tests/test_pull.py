
import os

from util import *

pull_expression = """
  pullImage {
    imageName = "nixos/nix";
    imageDigest = "sha256:50ece001fa4ad2a26c85b05c1f1c1285155ed5dffd97d780523526fc36316fb8";
    sha256 = "05vsbz3kaca87iw59b5sm4nfyn0mp7p3saw3fwcwzjflbfy8qb09";
    finalImageTag = "1.11";
  }
"""

layer_image_name = "layer_on_pull"
layer_image_tag = "layer_on_pull_tag"

layer_expression = """
  buildImageUnzipped {
    name = "%s";
    tag = "%s";
    fromImage = %s;
    contents = pkgs.file;
  }
""" % (layer_image_name, layer_image_tag, pull_expression)

def wrap(expression):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      %s
      """ % expression

    return raw.strip().replace("\n", " ")

def test_pull(tmpdir):
    validate_image(build_unzipped(wrap(pull_expression), tmpdir), num_symlink_layers=0)

def test_layer_on_pulled_layer(tmpdir):
    full_image_name = layer_image_name + ":" + layer_image_tag
    with docker_load(full_image_name, tar_image(wrap(layer_expression), tmpdir)):
        assert docker_command(full_image_name, "echo hi > some_file; file some_file") == "some_file: ASCII text\n"
