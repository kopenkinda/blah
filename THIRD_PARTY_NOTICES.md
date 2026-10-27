# Third-party notices

Blah is a new Swift application. Its dictation gestures and model choices follow
DK's Hex fork. Hex's MIT notice is included in LICENSE.

- Hex: https://github.com/kitlangton/Hex, copyright Christopher Langton, MIT.
- transcribe.cpp 0.1.3: https://github.com/handy-computer/transcribe.cpp, MIT.
- llama.cpp, source distributed in llama-cpp-sys-2 0.1.154:
  https://github.com/ggml-org/llama.cpp, MIT.
- GGML, included by both runtimes: https://github.com/ggml-org/ggml, MIT.

Model weights are external files and are not included in the application:

- Parakeet Unified English Q8_0:
  https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf
- Parakeet v2 and v3 Q8_0:
  https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf
  https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf
- Whisper large-v3-turbo Q8_0:
  https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf
  Upstream model: https://huggingface.co/openai/whisper-large-v3-turbo
- Qwen3-ASR 0.6B Q8_0:
  https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf
  Upstream model: https://huggingface.co/Qwen/Qwen3-ASR-0.6B
- Qwen3 4B Q4_K_M:
  https://huggingface.co/Qwen/Qwen3-4B-GGUF
- S1-mini by Superwhisper Q4_K_M:
  https://huggingface.co/superwhisper/s1-mini-GGUF
  S1-mini has its own model license. The settings identify Superwhisper.

The build downloads checksum-pinned native source archives. No Rust code is
compiled or included in Blah.

## Windows frontend and packaging

The Windows frontend bundles Python 3.13 (PSF license), Tcl/Tk (Tcl/Tk license),
sounddevice (MIT), PortAudio (MIT), pystray (LGPL-3.0), Pillow (HPND), cffi (MIT),
pycparser (BSD-3-Clause), and six (MIT). PyInstaller uses GPL-2.0-or-later with its
bootloader exception permitting distribution of the packaged application.

- Python: https://www.python.org/psf/license/
- Tcl/Tk: https://www.tcl-lang.org/software/tcltk/license.html
- sounddevice: https://github.com/spatialaudio/python-sounddevice
- PortAudio: https://www.portaudio.com/license.html
- pystray: https://github.com/moses-palmer/pystray
- Pillow: https://github.com/python-pillow/Pillow
- cffi: https://cffi.readthedocs.io/en/latest/license.html
- pycparser: https://github.com/eliben/pycparser
- six: https://github.com/benjaminp/six
- PyInstaller: https://pyinstaller.org/en/stable/license.html

Windows distributions include `THIRD_PARTY_LICENSES` with dependency license
texts and Python's license. The pystray source is available at the link above,
tag v0.19.5; it is an unmodified, separately importable module inside the packaged
Python archive. Recipients may replace it by running the supplied frontend source
with a modified pystray package and rebuilding with the provided spec/script.

MinGW builds may bundle its winpthreads runtime (MIT), MinGW-w64 runtime
(permissive notices), libgcc/libstdc++ (GCC Runtime Library Exception). MSVC builds
do not bundle those libraries. See https://www.mingw-w64.org/ and
https://www.gnu.org/licenses/gcc-exception-3.1.html. w64devkit itself is a build
tool and is not included in the app. Model weights remain external.

## transcribe.cpp license

MIT License

Copyright (c) 2026 The transcribe.cpp authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## llama.cpp and GGML license

MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## miniz license

Copyright 2013-2014 RAD Game Tools and Valve Software
Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC

All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## VoiceOrbs Particles Orb license

The native particle indicator adapts the sphere geometry and motion from
https://github.com/amunozdev/voiceorbs.

MIT License

Copyright (c) 2026 Alexis Munoz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
