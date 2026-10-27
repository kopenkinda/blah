from pathlib import Path

root = Path(SPECPATH).parent
runtimes = root / '.build/windows/runtimes'
for filename in ('blah_speech.dll', 'blah_cleanup.dll'):
    if not (runtimes / filename).exists():
        raise RuntimeError('Build Windows native runtimes first: ' + filename)
a = Analysis([str(root / 'Windows/main.py')], pathex=[str(root / 'Windows')],
             binaries=[(str(p), 'runtimes') for p in runtimes.glob('*.dll')],
             datas=[], hiddenimports=['pystray._win32'], hookspath=[], runtime_hooks=[],
             excludes=[], noarchive=False)
# Blah uses WASAPI only; omit the optional ASIO SDK binary from the wheel.
a.binaries = [entry for entry in a.binaries if '-asio.dll' not in entry[0].lower()]
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='Blah', debug=False,
          bootloader_ignore_signals=False, strip=False, upx=False, console=False,
          disable_windowed_traceback=False)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='Blah')
