"""Build the oracle against the verified source selected by the manifest."""

import json
import os
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory
import tomllib

from fetch import digest, retain_verified_tree
from run import rust_environment
from source_wire import wire_version


def dependency(cargo_manifest):
    contents = cargo_manifest.read_text()
    configuration = tomllib.loads(contents)['dependencies']['fortress-rollback']
    if configuration.get('default-features') is not False or configuration.get('features', []) != []:
        raise ValueError('oracle Cargo dependency features differ from the baseline')
    return contents, configuration['path']


def manifest_for_source(original, new_manifest, source_tree):
    contents, path = dependency(original)
    anchor = json.dumps(path, ensure_ascii=False)
    if contents.count(anchor) != 1:
        raise ValueError('oracle Cargo dependency anchor changed')
    selected = Path(os.path.relpath(source_tree, new_manifest.parent)).as_posix()
    return contents.replace(anchor, json.dumps(selected, ensure_ascii=False))


def source_build_environment(cargo_manifest, source_tree, revision):
    wire_version(revision)
    _, path = dependency(cargo_manifest)
    if (cargo_manifest.parent / path).resolve() != source_tree.resolve():
        raise ValueError('oracle Cargo dependency differs from selected Fortress archive')
    environment = rust_environment()
    environment['FORTRESS_ORACLE_SOURCE_REVISION'] = revision
    return environment


def prepare_source_build(cargo_manifest, source_tree, revision, cache):
    wire_version(revision)
    _, path = dependency(cargo_manifest)
    if (cargo_manifest.parent / path).resolve() == source_tree.resolve():
        return cargo_manifest
    parent = cache / 'oracle-source-build'
    parent.mkdir(parents=True, exist_ok=True)
    adapter = parent / revision
    with TemporaryDirectory(dir=parent) as temporary:
        staged = Path(temporary)
        (staged / 'Cargo.toml').write_text(manifest_for_source(cargo_manifest, adapter / 'Cargo.toml', source_tree))
        shutil.copyfile(cargo_manifest.with_name('Cargo.lock'), staged / 'Cargo.lock')
        shutil.copytree(cargo_manifest.parent / 'src', staged / 'src')
        retain_verified_tree(staged, adapter)
    return adapter / 'Cargo.toml'


def upstream_inventory(tree):
    paths = [*tree.rglob('*.rs'), tree / 'Cargo.toml', tree / 'Cargo.lock']
    return {str(path.relative_to(tree)): digest(path) for path in sorted(paths)}
