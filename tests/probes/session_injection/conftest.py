"""Probe-suite conftest.

Live probes share a harness session across sibling probe functions (e.g. P1 -> P3
-> P4 on one claude-code session), so execution MUST follow definition order.
pytest-randomly (installed in this repo) otherwise shuffles items. Force
definition (line-number) order for everything collected under this directory.
"""


def pytest_collection_modifyitems(items):
    def sort_key(item):
        # Keep only items from this probe directory in definition order; leave
        # others untouched relative to each other.
        try:
            return item.function.__code__.co_firstlineno
        except AttributeError:
            return 0

    items.sort(key=sort_key)
