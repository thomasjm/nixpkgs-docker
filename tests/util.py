
from contextlib import contextmanager
import docker
import json
import os
import subprocess

def validate_image(image_dir, num_layers=None, num_symlink_layers=None):
    """Perform sanity checks to validate that a Docker image folder is well-formed"""
    assert os.path.isdir(image_dir)

    manifest_path = image_dir.join("manifest.json")

    assert os.path.isfile(manifest_path)

    with open(manifest_path) as f:
        manifest = json.loads(f.read())

    layers = []
    config_path = None
    for section in manifest:
        for layer in section["Layers"]:
            assert os.path.isfile(image_dir.join(layer))
            layers.append(image_dir.join(layer))

        assert section["Config"]
        config_path = section["Config"]

        assert os.path.isfile(image_dir.join(section["Config"]))

    if num_layers is not None:
        assert len(layers) == num_layers

    if num_symlink_layers is not None:
        assert len([x for x in layers if os.path.islink(x)]) == num_symlink_layers

    # Check layer sha256 hashes
    with open(image_dir.join(config_path)) as f:
        config = json.loads(f.read())
    for (layer, desired_hash) in zip(layers, config["rootfs"]["diff_ids"]):
        found_hash = subprocess.check_output(["sha256sum", layer]).decode().split(" ")[0]
        assert "sha256:" + found_hash == desired_hash

@contextmanager
def docker_load(full_image_name, tarball):
    try:
        subprocess.run(["docker", "load", "--input=" + str(tarball)], check=True)
        yield
    finally:
        client = docker.from_env()
        client.images.remove(image=full_image_name, force=True)


def docker_command(full_image_name, command):
    return subprocess.check_output(["docker", "run", "-i", "--rm", full_image_name,
                                    "bash", "-c", command]).decode()

def tar_image(expression, cwd):
    subprocess.run(["nix-build", "-E",
                    "with import <nixpkgs> {}; with dockerTools; tarImage { fromImage = %s; }" % expression,
                    "-o", "output"],
                   cwd=cwd, check=True)

    return cwd.join("output")

def build_unzipped(expression, cwd):
    subprocess.run(["nix-build", "-E", expression, "-o", "output"],
                   cwd=cwd, check=True)

    return cwd.join("output")

def tar_file_contains(path, needle):
    contents = subprocess.check_output(["tar", "-tf", path]).decode()
    return needle in contents
