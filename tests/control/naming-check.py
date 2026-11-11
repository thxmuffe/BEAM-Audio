"""Audit project-owned names; historical documents and generated dependencies are excluded."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent
HISTORY = {'old-ideas', 'discarded-ideas', 'possibly-useful', 'decisions'}
HISTORICAL_FILES = {'PROGRESS.md', 'OPENSOUND_LEGACY_README.md'}
# Split historical spellings so this audit obeys the same naming rule.
OBSOLETE = re.compile('|'.join(('sw' 'arm', 'par' 'vi', 'cap' 'tain', 'wait' 'or')), re.I)
errors = []
checked = 0
for repository in (ROOT, WORKSPACE / 'OpenSound'):
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=repository).decode().split('\0')
    for relative in sorted(set(paths) - {''}):
        path = repository / relative
        if not path.is_file():
            continue
        if HISTORY.intersection(path.relative_to(repository).parts) or path.name in HISTORICAL_FILES:
            continue
        if OBSOLETE.search(relative):
            errors.append(f'{repository.name}/{relative}: obsolete path')
        try:
            content = path.read_text()
        except UnicodeError:
            continue
        checked += 1
        if OBSOLETE.search(content):
            errors.append(f'{repository.name}/{relative}: obsolete vocabulary')
        if repository == ROOT and path.suffix == '.erl':
            module = re.search(r'^-module\((\w+)\)\.', content, re.M)
            if not module or module[1] != path.stem or not path.stem.startswith('ba_'):
                errors.append(f'{repository.name}/{relative}: module must match its ba_ filename')
assert not errors, '\n'.join(errors)
print(f'PASS: {checked} project-owned text files use current names')
