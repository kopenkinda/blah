#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
runtime_dir="$root/.build/runtimes"
source_dir="$root/.build/vendor"
mkdir -p "$runtime_dir" "$source_dir"

# These source releases match the GGUF runtimes used by the existing Hex fork.
# The crates are source archives only. No Rust toolchain or Hex checkout is used.
fetch_source() {
    local name="$1" version="$2" checksum="$3"
    local archive="$source_dir/$name-$version.crate"
    if [ ! -f "$archive" ]; then
        local cached
        for cached in "$HOME"/.cargo/registry/cache/*/"$name-$version.crate"; do
            if [ -f "$cached" ]; then cp "$cached" "$archive"; break; fi
        done
        if [ ! -f "$archive" ]; then
            curl -fL --retry 3 "https://static.crates.io/crates/$name/$name-$version.crate" -o "$archive"
        fi
    fi
    printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
    if [ ! -d "$source_dir/$name-$version" ]; then tar -xf "$archive" -C "$source_dir"; fi
}

if [ ! -f "$runtime_dir/transcribe/lib/libtranscribe.a" ]; then
    fetch_source transcribe-cpp-sys 0.1.3 278fd6a6da4d9d8d5f2716bd6761a76ea55c129fda6ba57856b80249a8570ed4
    cmake -S "$source_dir/transcribe-cpp-sys-0.1.3" -B "$runtime_dir/transcribe/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$runtime_dir/transcribe" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DTRANSCRIBE_BUILD_SHARED=OFF -DTRANSCRIBE_INSTALL=ON \
        -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
        -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DTRANSCRIBE_USE_OPENMP=OFF
    cmake --build "$runtime_dir/transcribe/build" --config Release --target install --parallel 6
fi

if [ ! -f "$runtime_dir/llama/lib/libllama.a" ]; then
    fetch_source llama-cpp-sys-2 0.1.154 13a9ea2ce0cdc20bcb1870534022e340b391663f8fe09133951e2fe37fbc29cf
    cmake -S "$source_dir/llama-cpp-sys-2-0.1.154/llama.cpp" -B "$runtime_dir/llama/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$runtime_dir/llama" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF -DGGML_OPENMP=OFF
    cmake --build "$runtime_dir/llama/build" --config Release --target install --parallel 6
fi
