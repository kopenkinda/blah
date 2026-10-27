param(
    [string]$Python = 'python',
    [string]$Generator = 'Visual Studio 17 2022',
    [string]$CC = '',
    [string]$CXX = ''
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
function Run-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
Run-Checked -Program $Python -Arguments @('-m', 'venv', '.build/venv')
$py = Join-Path $PWD '.build/venv/Scripts/python.exe'
$env:PATH = (Join-Path $PWD '.build/venv/Scripts') + ';' + $env:PATH
Run-Checked -Program $py -Arguments @('-m', 'pip', 'install', '-r', 'Windows/requirements-build.txt')
Run-Checked -Program $py -Arguments @('-m', 'unittest', 'discover', '-s', 'Windows/tests', '-v')
$nativeArgs = @('scripts/build-windows-native.py', '--generator', $Generator)
if ($CC) { $nativeArgs += @('--cc', $CC) }
if ($CXX) { $nativeArgs += @('--cxx', $CXX) }
Run-Checked -Program $py -Arguments $nativeArgs
Run-Checked -Program $py -Arguments @('-m', 'PyInstaller', '--noconfirm', 'Windows/Blah.spec')
$report = Join-Path $PWD '.build/windows/package-self-test.json'
if (Test-Path $report) { Remove-Item -LiteralPath $report }
$process = Start-Process -FilePath 'dist/Blah/Blah.exe' -ArgumentList @('--self-test', '--report', ('"' + $report + '"')) -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Packaged self-test timed out' }
if ($process.ExitCode -ne 0 -or -not (Test-Path $report)) { throw 'Packaged self-test failed' }
Get-Content $report
Copy-Item LICENSE,THIRD_PARTY_NOTICES.md,Windows/README.md -Destination dist/Blah
Run-Checked -Program $py -Arguments @('scripts/collect-windows-licenses.py')
Compress-Archive -Path 'dist/Blah' -DestinationPath 'dist/Blah-Windows-x64.zip' -Force
Write-Output 'Built dist/Blah-Windows-x64.zip. Extract it and run Blah/Blah.exe.'
