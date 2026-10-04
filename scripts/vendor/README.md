# Vendored Python packages

Lore runs on whatever `python3` (3.9+) a machine already has, and needs nothing
from pip. Python libraries it depends on are copied here and loaded from this
directory, so an install never asks anyone to `pip install` into a system or
Homebrew Python (which PEP 668 refuses anyway).

| Package | Version | Source | sha256 of source archive | License |
|---|---|---|---|---|
| `yaml/` (PyYAML) | 6.0.3 | https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz | `d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f` | MIT (`yaml/LICENSE`) |

`yaml/` is the sdist's `lib/yaml/` unmodified. Without the optional libyaml C
extension, PyYAML runs as pure Python. `yaml.safe_load` uses the pure-Python
`SafeLoader` either way, so behaviour matches an installed PyYAML.

Consumers put this directory on `sys.path` (or `PYTHONPATH` for shell-embedded
Python) before `import yaml`. `tests/test_portability.py` checks that every
`import yaml` in shipped code does this.

To update: download the new sdist from PyPI, check its sha256 against the one
PyPI publishes, replace `yaml/` with the sdist's `lib/yaml/`, copy `LICENSE`, and
update this table.
