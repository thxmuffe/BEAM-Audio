"""Runner behavior checks; no application, hardware or network is opened."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('repository_test_runner', Path(__file__).with_name('run-tests.py'))
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_failure_and_unavailable_do_not_stop_later_tests(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            tests = [runner.Test('failure', [sys.executable, '-c', 'raise SystemExit(7)'], root),
                     runner.Test('missing', [sys.executable], root, required=(root/'absent',)),
                     runner.Test('later', [sys.executable, '-c', 'from pathlib import Path; Path("ran").touch()'], root)]
            with contextlib.redirect_stdout(io.StringIO()):
                results = runner.execute(tests, dict(os.environ))
            self.assertEqual(['FAILED', 'UNAVAILABLE', 'PASSED'], [r['status'] for r in results])
            self.assertTrue((root/'ran').exists())
            self.assertEqual(1, runner.exit_code(results))
            self.assertEqual(2, runner.exit_code(results[1:]))
            self.assertEqual(0, runner.exit_code(results[2:]))

    def test_inventory_contains_all_discovered_runners_and_audio_cases(self):
        tests = runner.catalog(runner.CORE.parent/'OpenSound')
        self.assertIn('/src/control/rebar.config', tests[0].name)
        self.assertEqual(['do', 'compile,', 'eunit'], tests[0].command[-3:])
        paths = {str(Path(t.command[1]).resolve()) for t in tests if len(t.command)>1}
        for p in runner.files(runner.CORE/'tests'):
            if p.name.endswith(('-smoke.py', '-e2e.py', '.escript')) or p.name in {'smoke.py', 'naming-check.py'}:
                self.assertIn(str(p.resolve()), paths, str(p))
        self.assertTrue(any('DeviceWeb/rebar.config' in t.name for t in tests))
        self.assertTrue(any('tests/UI/Package.swift' in t.name for t in tests))


if __name__ == '__main__':
    unittest.main()
