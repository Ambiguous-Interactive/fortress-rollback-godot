"""Freeze engine-generated import metadata without accepting changed authored sources."""
from signalfish_probe import inventory


def metadata_source(name, uid_suffixes):
    if name.endswith(uid_suffixes):
        return name[:-4]
    if name.endswith('.import'):
        return name[:-7]
    return None


def freeze_after_import(paths, before, uid_suffixes=('.gd.uid',)):
    after = inventory(paths)
    for name, expected in before.items():
        source = metadata_source(name, uid_suffixes)
        if name not in after or (source not in before and after[name] != expected):
            raise ValueError('authored Web source changed during editor import: ' + name)
    for name in after.keys() - before.keys():
        source = metadata_source(name, uid_suffixes)
        if source not in before:
            raise ValueError('unexpected editor-generated Web file: ' + name)
    return after
