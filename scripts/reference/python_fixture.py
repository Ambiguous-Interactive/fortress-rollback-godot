"""Write executable Python fixtures without shebang path restrictions."""
from pathlib import Path
import shlex
import sys


def write_executable(path: Path, program: str, interpreter: str = sys.executable) -> None:
    bootstrap = ("import os,sys;sys.argv=sys.argv[1:];"
                 "identity=sys.argv[0] if os.path.isabs(sys.argv[0]) else os.path.join(os.getcwd(),sys.argv[0]);"
                 f"exec(compile({program!r},identity,'exec'),"
                 "{'__name__':'__main__','__file__':identity})")
    path.write_text('#!/bin/sh\nexec ' + shlex.quote(str(interpreter)) + ' -c ' + shlex.quote(bootstrap) + ' "$0" "$@"\n', encoding='utf-8')
    path.chmod(0o755)
