#!/bin/bash
# Builds the pinned NeMo-Speech.cpp ASR C library (Metal) into .runtime/lib,
# plus libllama from the same llama.cpp tree for the cleanup model, so both
# share one ggml. Rerunning is a no-op once built.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_COMMIT=536b17a41bef62d2a67a40ed3df61df26a4389fe
LLAMA_COMMIT=bd4f514db14d87fded667787a7a963bfbaa98e89
ROOT="$PWD/.runtime"
SRC="$ROOT/source"
LIB="$ROOT/lib"
# Install names the C library links against, plus its own.
LIBS=(libnemo_speech_asr_c.2.dylib libnemo_speech_asr.dylib libllama.0.dylib libggml.0.dylib libggml-base.0.dylib
      libggml-blas.0.dylib libggml-cpu.0.dylib libggml-metal.0.dylib)
# Matches LSMinimumSystemVersion in Resources/Info.plist.
export MACOSX_DEPLOYMENT_TARGET=26.0
MARKER="$LIB/.built-$SOURCE_COMMIT-llama-macos$MACOSX_DEPLOYMENT_TARGET"

if [ -f "$MARKER" ]; then
    echo "Runtime already built at $LIB"
    exit 0
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# The sentencepiece build script requires Ninja; take a pinned wheel.
NINJA_BIN="$(dirname "$(uv run --quiet --no-project --with ninja==1.13.2 python -c 'import shutil; print(shutil.which("ninja"))')")"
export PATH="$NINJA_BIN:$PATH"

mkdir -p "$ROOT"
if [ ! -d "$SRC/.git" ]; then
    git clone --filter=blob:none --no-checkout https://github.com/NVIDIA/NeMo-Speech.cpp.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$SOURCE_COMMIT"
git -C "$SRC" checkout --quiet --detach "$SOURCE_COMMIT"
git -C "$SRC" submodule update --init --depth 1 llama.cpp
[ "$(git -C "$SRC/llama.cpp" rev-parse HEAD)" = "$LLAMA_COMMIT" ] || { echo "Unexpected llama.cpp revision" >&2; exit 1; }

(cd "$SRC" && bash scripts/build_sentencepiece_static.sh)
cmake -S "$SRC" -B "$ROOT/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DNEMO_SPEECH_BUILD_TTS=OFF -DNEMO_SPEECH_BUILD_DIAR=OFF -DNEMO_SPEECH_BUILD_HTTP=OFF \
    -DNEMO_SPEECH_BUILD_CLI=OFF -DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF -DNEMO_SPEECH_BUILD_TESTS=OFF \
    -DNEMO_SPEECH_BUILD_EXAMPLES=OFF -DNEMO_SPEECH_BUILD_NMT=ON
# NMT=ON only adds llama.cpp on top of the ASR's ggml; build just libllama from it.
cmake --build "$ROOT/build" --target nemo_speech_asr_c llama -j 8

rm -rf "$LIB"
mkdir -p "$LIB"
for name in "${LIBS[@]}"; do cp -L "$ROOT/build/bin/$name" "$LIB/$name"; done
ln -s libnemo_speech_asr_c.2.dylib "$LIB/libnemo_speech_asr_c.dylib"
ln -s libllama.0.dylib "$LIB/libllama.dylib"
cp "$SRC/LICENSE" "$SRC/NOTICE" "$SRC/THIRD_PARTY_NOTICES.md" "$LIB/"
cp "$SRC/llama.cpp/LICENSE" "$LIB/LICENSE-llama.cpp"
# Sources/CLlama/include vendors these headers from NeMo's patched llama.cpp; fail if they drift.
PATCHED="$ROOT/build/_deps/llama.cpp"
for h in include/llama.h ggml/include/ggml.h ggml/include/ggml-cpu.h ggml/include/ggml-backend.h \
         ggml/include/ggml-opt.h ggml/include/ggml-alloc.h ggml/include/gguf.h; do
    cmp -s "$PATCHED/$h" "Sources/CLlama/include/$(basename "$h")" || { echo "Sources/CLlama/include/$(basename "$h") differs from $h" >&2; exit 1; }
done
touch "$MARKER"
echo "Built $LIB"
