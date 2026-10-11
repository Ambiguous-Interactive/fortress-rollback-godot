"""Freeze engine-generated import metadata without accepting changed authored sources."""
from signalfish_probe import inventory


def freeze_after_import(paths, before):
    after = inventory(paths)
    for name, expected in before.items():
        source = name[:-4] if name.endswith('.gd.uid') else name[:-7] if name.endswith('.import') else None
        if name not in after or (source not in before and after[name] != expected):
            raise ValueError('authored Web source changed during editor import: ' + name)
    for name in after.keys() - before.keys():
        source = name[:-4] if name.endswith('.gd.uid') else name[:-7] if name.endswith('.import') else None
        if source not in before:
            raise ValueError('unexpected editor-generated Web file: ' + name)
    return after
