"""Invalidate only the selected witness receipt when argument validation fails."""
import argparse
from pathlib import Path
import sys


def preview_arguments(arguments):
    preview = argparse.ArgumentParser(add_help=False, allow_abbrev=False, exit_on_error=False)
    preview.add_argument('--output', type=Path, nargs='?', action='append', default=[])
    preview.add_argument('--online-example', nargs='?', const=True)
    selected, _unknown = preview.parse_known_args(arguments)
    selected.output = next((path for path in reversed(selected.output) if path is not None), None)
    return selected


class StrictHelp(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        if values is not True:
            parser.error(f'argument {option_string}: does not accept a value')
        parser.print_help()
        parser.exit()


class ReceiptParser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs['allow_abbrev'] = False
        kwargs['add_help'] = False
        super().__init__(*args, **kwargs)
        self.add_argument('-h', '--help', action=StrictHelp, nargs='?', const=True, default=argparse.SUPPRESS,
                          help='show this help message and exit')
        self.receipt_preview = None

    def parse_args(self, args=None, namespace=None):
        arguments = list(sys.argv[1:] if args is None else args)
        self.receipt_preview = preview_arguments(arguments)
        return super().parse_args(arguments, namespace)

    def error(self, message):
        selected = self.receipt_preview
        if selected is not None and selected.output is not None:
            name = 'online-example.json' if selected.online_example is not None else 'signalfish-webrtc.json'
            try:
                selected.output.mkdir(parents=True, exist_ok=True)
                (selected.output / name).write_text('{"passed": false, "failure": "invalid_arguments"}\n', encoding='utf-8')
            except OSError:
                message += '; unable to invalidate the selected receipt'
        super().error(message)
