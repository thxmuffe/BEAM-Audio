"""Check project-owned Erlang file/module names; never inspect generated dependencies."""
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
errors=[]
files=[*ROOT.joinpath('src').rglob('*.erl'),*ROOT.joinpath('tests').rglob('*.erl')]
for file in files:
    text=file.read_text()
    module=re.search(r'^-module\((\w+)\)\.',text,re.M)
    if not module or module[1]!=file.stem or not file.stem.startswith('ba_'):
        errors.append(f'{file.relative_to(ROOT)}: module must match its ba_ filename')
    if file.relative_to(ROOT).parts[0]=='src':
        if re.search(r'\bparvi(?:_\w+)?\s*:\s*[a-z]\w*\s*\(',text):
            errors.append(f'{file.relative_to(ROOT)}: old core call')
        if 'PARVI_' in text:
            errors.append(f'{file.relative_to(ROOT)}: old environment variable')
assert not errors,'\n'.join(errors)
print(f'PASS: {len(files)} Erlang files match ba_ module names; source calls/config use the current namespace')
