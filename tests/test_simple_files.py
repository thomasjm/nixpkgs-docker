
import pytest
from util import *

simple_files_derivation = """stdenv.mkDerivation {
  name = "simple-files-derivation";
  src = ./src;
  buildPhase = "true";
  installPhase = "mkdir -p $out && cp -r ./* $out";
}"""

def get_unzipped_image_expression(name, tag):
    raw = """
      with import <nixpkgs> {};
      with dockerTools;
      let simpleFiles = %s; in
        buildImageUnzipped {
          name = "%s";
          tag = "%s";
          contents = [simpleFiles pkgs.bashInteractive which coreutils];
        }
      """ % (simple_files_derivation, name, tag)

    return raw.strip().replace("\n", " ")

@pytest.fixture(scope="session")
def dir_with_src(tmpdir_factory):
    base = tmpdir_factory.mktemp("base")
    os.mkdir(base.join("src"))
    with open(base.join("src").join("sample.txt"), 'w') as f:
        f.write("Sample contents")
    return base

def test_valid(dir_with_src):
    validate_image(build_unzipped(get_unzipped_image_expression("some_image_name", "some_tag"), dir_with_src),
                   num_layers=1, num_symlink_layers=0)

def test_docker_load(dir_with_src):
    image_name = "bash_image"
    image_tag = "bash_tag"
    unzipped_image_expression = get_unzipped_image_expression(image_name, image_tag)

    # full_simple_files_derivation = "with import <nixpkgs> {};\n" + simple_files_derivation
    store_path = subprocess.check_output(["nix-build", "-E",
                                          "with import <nixpkgs> {}; " + simple_files_derivation],
                                         cwd=dir_with_src).decode().strip()

    tarball = tar_image(unzipped_image_expression, dir_with_src)
    full_image_name = image_name + ":" + image_tag
    with docker_load(full_image_name, tarball):
        # The store path should exist
        assert docker_command(full_image_name, "if [ -d %s ]; then echo success; else echo failure; fi" % store_path).strip() == "success"
        # sample.txt should exist within the store path
        assert docker_command(full_image_name, "if [ -f %s/sample.txt ]; then echo success; else echo failure; fi" % store_path).strip() == "success"
        # sample.txt should not end up at the root
        assert docker_command(full_image_name, "if [ ! -f /sample.txt ]; then echo success; else echo failure; fi").strip() == "success"

        # Binaries should be symlinked to their location in the Nix store
        assert docker_command(full_image_name, "which which").strip() == "/bin/which"
        assert docker_command(full_image_name, "if [ -L /bin/which ]; then echo success; else echo failure; fi").strip() == "success"
        which_store_path = subprocess.check_output(["nix-build", "<nixpkgs>", "-A", "which"]).decode().strip()
        print("which_store_path: ", which_store_path)
        assert docker_command(full_image_name, "readlink -f /bin/which").strip() == which_store_path + "/bin/which"
