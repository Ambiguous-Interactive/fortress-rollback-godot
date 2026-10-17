"""Invalidate only the selected launcher receipt when argument parsing or validation fails."""
import argparse
from pathlib import Path
import sys


def preview_arguments(arguments, variants=()):
    preview = argparse.ArgumentParser(add_help=False, allow_abbrev=False, exit_on_error=False)
    preview.add_argument('--output', nargs='?', action='append', default=[])
    for flag in variants:
        preview.add_argument(flag, nargs='?', const=True)
    selected, _unknown = preview.parse_known_args(arguments)
    return selected


class StrictHelp(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        if values is not True:
            parser.error(f'argument {option_string}: does not accept a value')
        parser.print_help()
        parser.exit()


class ReceiptParser(argparse.ArgumentParser):
    """Use `receipt` in the last named `--output`, its default, or a fixed `output`; `variants` maps flags to other receipt names."""

    def __init__(self, *args, receipt, output=None, variants=None, **kwargs):
        kwargs['allow_abbrev'] = False
        kwargs['add_help'] = False
        super().__init__(*args, **kwargs)
        self.add_argument('-h', '--help', action=StrictHelp, nargs='?', const=True, default=argparse.SUPPRESS,
                          help='show this help message and exit')
        self.receipt, self.fixed_output, self.variants, self.receipt_preview = receipt, output, variants or {}, None

    def parse_args(self, args=None, namespace=None):
        arguments = list(sys.argv[1:] if args is None else args)
        self.receipt_preview = preview_arguments(arguments, self.variants)
        return super().parse_args(arguments, namespace)

    def selected_receipt(self):
        selected = self.receipt_preview
        if selected is None:
            return None
        output = self.fixed_output
        if output is None and selected.output:
            output = next((Path(path) for path in reversed(selected.output) if path), None)
        elif output is None and '--output' in self._option_string_actions:
            output = self._option_string_actions['--output'].default
        if output is None:
            return None
        name = next((name for flag, name in self.variants.items() if getattr(selected, flag[2:].replace('-', '_')) is not None), self.receipt)
        return Path(output) / name

    def error(self, message):
        receipt = self.selected_receipt()
        if receipt is not None:
            try:
                receipt.parent.mkdir(parents=True, exist_ok=True)
                receipt.write_text('{"passed": false, "failure": "invalid_arguments"}\n', encoding='utf-8')
            except OSError:
                message += '; unable to invalidate the selected receipt'
        super().error(message)
