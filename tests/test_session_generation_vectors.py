import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VECTORS = ROOT / 'tests/fixtures/session-generation-vectors.json'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


T = load('session_target_under_test', ROOT / 'scripts/session_target.py')


class SessionGenerationVectors(unittest.TestCase):
    """scripts/session_target.py generation() against the vectors the Go
    session.Generation test (tui/internal/session/generation_test.go) also reads."""

    def vectors(self):
        vectors = json.loads(VECTORS.read_text())['vectors']
        self.assertTrue(vectors, 'the vector file holds no vectors')
        return vectors

    def test_generation_matches_every_shared_vector(self):
        for vector in self.vectors():
            with self.subTest(vector['name']):
                self.assertEqual(T.generation(vector['row']), vector['generation'])

    def test_a_row_missing_a_field_reads_as_that_field_empty(self):
        for vector in self.vectors():
            row = {key: value for key, value in vector['row'].items() if value}
            with self.subTest(vector['name']):
                self.assertEqual(T.generation(row), vector['generation'])


if __name__ == '__main__':
    unittest.main()
