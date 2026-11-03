"""Bundle Mix runtime dependencies and relocate their Mach-O dependencies."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
resources = Path(sys.argv[1]).resolve()
destination = resources / 'runtime/native_lib'
transport = ROOT / 'builds/intermediates/BeamTransport/dev/lib'
elixir = ROOT / 'builds/intermediates/tools/elixir/lib'
if not elixir.is_dir():
    # A normal system Mix installation is supported alongside the pinned cache.
    elixir = Path(subprocess.check_output(['elixir', '-e',
        'IO.puts(Path.dirname(:code.lib_dir(:elixir)))'], text=True).strip())

if destination.exists():
    shutil.rmtree(destination)
destination.mkdir(parents=True)
licenses = resources / 'NativeTransportLicenses'
licenses.mkdir(exist_ok=True)
for library in [*sorted(transport.iterdir()), elixir / 'elixir', elixir / 'eex', elixir / 'logger']:
    target = destination / library.name
    for folder in ['ebin', 'priv']:
        source = library / folder
        if source.is_dir():
            # Mix priv directories contain symlinks into the build cache.
            shutil.copytree(source, target / folder, symlinks=False)
    source = ROOT / 'builds/intermediates/BeamTransportDeps' / library.name
    for base in [library, source]:
        if base.is_dir():
            for license in base.glob('*'):
                if license.is_file() and license.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                    shutil.copy2(license, licenses / f'{library.name}-{license.name}')

def output(*args):
    return subprocess.check_output(args, text=True)

processed = set()
origins = {}

def bundle(binary):
    if binary in processed:
        return
    processed.add(binary)
    binary.chmod(binary.stat().st_mode | 0o200)
    links = [line.strip().split(' (', 1)[0]
             for line in output('otool', '-L', str(binary)).splitlines()[1:]]
    install_ids = output('otool', '-D', str(binary)).splitlines()[1:]
    # Resolve existing upstream rpaths before replacing links with bundle-local paths.
    rpaths = re.findall(r'\bpath (.+?) \(offset', output('otool', '-l', str(binary)))
    search = [Path(p.replace('@loader_path', str(binary.parent))) for p in rpaths]
    search += [Path('/opt/homebrew/opt/openssl@3/lib')]
    for link in links:
        if link in install_ids:
            continue
        if link.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if link.startswith('@rpath/'):
            candidates = [p / link.removeprefix('@rpath/') for p in search]
        elif link.startswith('@loader_path/'):
            suffix = link.removeprefix('@loader_path/')
            candidates = [binary.parent / suffix, origins.get(binary, binary).parent / suffix]
        else:
            candidates = [Path(link)]
        source = next((p for p in candidates if p.is_file()), None)
        if source is None:
            raise RuntimeError(f'Cannot resolve {link} required by {binary}')
        if source.resolve() == binary.resolve():
            continue  # Mach-O install ID, not a dependency.
        # Short sibling links fit upstream Mach-O headers without relinking NIFs.
        local = binary.parent / source.name
        if not local.exists():
            shutil.copy2(source, local)
            origins[local] = source
        subprocess.run(['install_name_tool', '-change', link,
                        '@loader_path/' + local.name, str(binary)], check=True)
        bundle(local)
    if binary.suffix == '.dylib':
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + binary.name,
                        str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)

for binary in sorted(destination.rglob('*')):
    if binary.suffix in ('.so', '.dylib') and binary.is_file():
        bundle(binary)

for source in [elixir.parent / 'LICENSE', elixir.parent / 'LICENSE.txt',
               Path('/opt/homebrew/opt/openssl@3/LICENSE.txt'),
               Path('/opt/homebrew/opt/openssl@4/LICENSE.txt')]:
    if source.is_file():
        shutil.copy2(source, licenses / f'{source.parent.name}-{source.name}')
print(f'Packaged native transport in {destination}')
