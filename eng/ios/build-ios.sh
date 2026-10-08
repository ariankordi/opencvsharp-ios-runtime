#!/usr/bin/env bash
# Builds OpenCvSharpExtern as a static xcframework (iOS device + simulator, arm64) from UNMODIFIED
# upstream sources plus the patches in eng/.
#
# Structure follows sdcb/opencvsharp-mini-runtime (Apache-2.0): upstream OpenCvSharp is checked out at a
# pinned tag and patched with eng/opencvsharp.patch. eng/opencvsharp-ios.patch is applied on top.
# The OpenCV configuration and the xcframework assembly are adapted from ariankordi/OpenCvSharp.iOS
# (src/tools/build-opencvsharp-ios.sh), written by Arian Kordi.
#
# Unlike that script this one generates NO abort stubs. The consuming app resolves P/Invokes at runtime and
# references only the symbols that really exist (see OpenCvSharpExtern.symbols.props, generated below).
#
# Usage:
#   build-ios.sh --opencv-src DIR --opencvsharp-src DIR --out DIR
#                [--managed-symbols FILE]
#                [--opencv-device-prefix DIR --opencv-simulator-prefix DIR]
#
#   --opencv-src                 opencv/opencv checkout (for its iOS toolchain files), e.g. tag 4.13.0.
#   --opencvsharp-src            shimat/opencvsharp checkout at the pinned tag. It is copied, not modified.
#   --out                        Output directory. Receives OpenCvSharpExtern.xcframework and the .props file.
#   --managed-symbols            Optional. One P/Invoke entry point per line (see pinvokes.cs). When given,
#                                OpenCvSharpExtern.symbols.props is generated from the intersection of this
#                                list and the symbols present in the built archive.
#   --opencv-*-prefix            Optional. Reuse an existing OpenCV install instead of building it. Both are
#                                required together.
#
# Prerequisites: Xcode, cmake >= 3.15, Ninja.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/.."
IOS_DEPLOYMENT_TARGET="13.0"

OPENCV_SRC=""
OPENCVSHARP_SRC=""
OUT_DIR=""
MANAGED_SYMBOLS=""
DEVICE_OPENCV_PREFIX=""
SIM_OPENCV_PREFIX=""

usage() {
    sed -n '/^# Usage:/,/^# Prerequisites/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

# Resolves a path to an absolute one, since the script changes directories freely.
absolute_path() {
    (cd "$1" && pwd)
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --opencv-src)               OPENCV_SRC="$(absolute_path "$2")"; shift 2 ;;
        --opencvsharp-src)          OPENCVSHARP_SRC="$(absolute_path "$2")"; shift 2 ;;
        --out)                      mkdir -p "$2"; OUT_DIR="$(absolute_path "$2")"; shift 2 ;;
        --managed-symbols)          MANAGED_SYMBOLS="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --opencv-device-prefix)     DEVICE_OPENCV_PREFIX="$(absolute_path "$2")"; shift 2 ;;
        --opencv-simulator-prefix)  SIM_OPENCV_PREFIX="$(absolute_path "$2")"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "$OPENCV_SRC" && -n "$OPENCVSHARP_SRC" && -n "$OUT_DIR" ]] || usage
if [[ -n "$DEVICE_OPENCV_PREFIX" && -z "$SIM_OPENCV_PREFIX" ]] || [[ -z "$DEVICE_OPENCV_PREFIX" && -n "$SIM_OPENCV_PREFIX" ]]; then
    echo "ERROR: pass both --opencv-device-prefix and --opencv-simulator-prefix, or neither." >&2
    exit 1
fi

PATCHED_SRC="$OUT_DIR/opencvsharp-src"
XCFRAMEWORK_OUT="$OUT_DIR/OpenCvSharpExtern.xcframework"
DEVICE_TOOLCHAIN="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneOS_Xcode.cmake"
SIM_TOOLCHAIN="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneSimulator_Xcode.cmake"
[[ -f "$DEVICE_TOOLCHAIN" && -f "$SIM_TOOLCHAIN" ]] || { echo "ERROR: iOS toolchain files not found under $OPENCV_SRC/platforms/ios" >&2; exit 1; }

export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"

# Minimal module set; must match what the patched OpenCvSharpExtern compiles (core, imgproc, imgcodecs).
OPENCV_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_LIST=core,imgproc,imgcodecs
    -DBUILD_SHARED_LIBS=OFF
    -DOPENCV_FORCE_3RDPARTY_BUILD=ON
    -DBUILD_EXAMPLES=OFF
    -DBUILD_opencv_apps=OFF
    -DBUILD_DOCS=OFF
    -DBUILD_PERF_TESTS=OFF
    -DBUILD_TESTS=OFF
    -DBUILD_JAVA=OFF
    -DWITH_PROTOBUF=OFF
    -DWITH_FFMPEG=OFF
    -DWITH_GSTREAMER=OFF
    -DWITH_V4L=OFF
    -DWITH_1394=OFF
    -DWITH_GTK=OFF
    -DWITH_OPENEXR=OFF
    -DWITH_QUIRC=OFF
    -DOPENCV_ENABLE_NONFREE=OFF
    -DIPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
    # KleidiCV passes -mcpu=armv8-a explicitly, which breaks when Xcode also compiles a fat simulator binary.
    -DWITH_KLEIDICV=OFF
    -DWITH_ADE=OFF
)

# Copies the OpenCvSharp sources and applies the patches, leaving the original checkout untouched.
prepare_patched_sources() {
    echo "=== Patch OpenCvSharp sources ==="
    rm -rf "$PATCHED_SRC"
    mkdir -p "$PATCHED_SRC"
    cp -R "$OPENCVSHARP_SRC/src" "$PATCHED_SRC/src"
    (
        cd "$PATCHED_SRC"
        # Without a ceiling, git finds an enclosing repository (e.g. when --out is inside a checkout) and then
        # silently SKIPS every path outside its subdirectory while still exiting 0. Hide the parents.
        export GIT_CEILING_DIRECTORIES="$OUT_DIR"
        # Order matters: the iOS patch is written against the file as left by sdcb's patch.
        git apply --verbose --ignore-whitespace "$PATCH_DIR/opencvsharp.patch"
        git apply --verbose "$PATCH_DIR/opencvsharp-ios.patch"
    )
    # Guard against a patch that "applied" without changing anything.
    local extern_cmake="$PATCHED_SRC/src/OpenCvSharpExtern/CMakeLists.txt"
    grep -q "NO_HIGHGUI=1" "$extern_cmake" || { echo "ERROR: eng/opencvsharp.patch did not take effect." >&2; exit 1; }
    grep -q "elseif(IOS)" "$extern_cmake" || { echo "ERROR: eng/opencvsharp-ios.patch did not take effect." >&2; exit 1; }
}

# Builds and installs static OpenCV for one slice. Arguments: slice name, toolchain file, install prefix.
build_opencv() {
    local slice="$1" toolchain="$2" prefix="$3"
    local build_dir="$OUT_DIR/opencv-build-$slice"
    echo "=== Build OpenCV [$slice] ==="
    mkdir -p "$build_dir"

    # The simulator SDK does not define __ARM_FP, which makes libjpeg-turbo's SIMD detection force NEON on
    # and then fail to compile. This switch skips the whole SIMD directory.
    local extra_cmake_args=()
    if [[ "$slice" == "simulator" ]]; then
        extra_cmake_args+=(-DENABLE_LIBJPEG_TURBO_SIMD=OFF)
    fi

    # Ninja avoids per-test xcodebuild overhead; STATIC_LIBRARY skips the link step in try_compile checks.
    cmake -S "$OPENCV_SRC" -B "$build_dir" -G Ninja \
        "${OPENCV_CMAKE_ARGS[@]}" \
        ${extra_cmake_args[@]+"${extra_cmake_args[@]}"} \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DIOS_ARCH=arm64 \
        -DCMAKE_INSTALL_PREFIX="$prefix"
    cmake --build "$build_dir" --config Release --parallel
    cmake --install "$build_dir" --config Release
}

# Builds libOpenCvSharpExtern.a for one slice. Arguments: slice name, toolchain file, OpenCV prefix.
build_extern() {
    local slice="$1" toolchain="$2" opencv_prefix="$3"
    local build_dir="$OUT_DIR/extern-$slice"
    echo "=== Build OpenCvSharpExtern [$slice] ==="
    mkdir -p "$build_dir"
    # Module selection comes from the glob and NO_* definitions in eng/opencvsharp.patch.
    cmake -S "$PATCHED_SRC/src" -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DNO_INSTALL_TO_TEST=ON \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DIOS_ARCH=arm64 \
        -DIPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DOpenCV_DIR="$opencv_prefix/lib/cmake/opencv4"
    cmake --build "$build_dir" --config Release --parallel
}

# Merges Extern and every OpenCV/3rdparty archive into one static library, so the app links a single file.
# Arguments: OpenCV prefix, extern build dir, output archive.
merge_static() {
    local opencv_prefix="$1" extern_dir="$2" merged_out="$3"
    echo "=== Merge static archives -> $(basename "$merged_out") ==="
    local extern_a="$extern_dir/OpenCvSharpExtern/libOpenCvSharpExtern.a"
    local opencv_libs=()
    while IFS= read -r -d '' lib; do
        opencv_libs+=("$lib")
    done < <(find "$opencv_prefix/lib" -name "*.a" -print0)

    # libtool warns about empty objects from disabled modules; grep's exit 1 must not trip pipefail.
    libtool -static -o "$merged_out" "$extern_a" "${opencv_libs[@]}" 2>&1 \
        | grep -v "^libtool: warning\|^ranlib: warning" || true
    echo "Merged: $(du -sh "$merged_out" | cut -f1)"
}

# lipo cannot merge two arm64 slices that differ only by SDK, so xcodebuild tags them via Info.plist.
assemble_xcframework() {
    local device_a="$1" sim_a="$2"
    echo "=== Assemble xcframework ==="
    rm -rf "$XCFRAMEWORK_OUT"
    xcodebuild -create-xcframework -library "$device_a" -library "$sim_a" -output "$XCFRAMEWORK_OUT"
}

# Writes the app-side symbol list: managed P/Invoke entry points that the archive really defines.
# Entry points the managed assembly declares but the trimmed archive lacks are simply left out; they are never
# resolved unless called, which is the same lazy behavior as a dynamic library.
generate_symbols_props() {
    local device_a="$1"
    echo "=== Generate symbols props ==="
    local native_symbols="$OUT_DIR/native-symbols.txt"
    local present="$OUT_DIR/entry-points-present.txt"
    # Defined global symbols with the Mach-O leading underscore removed.
    nm -gUj "$device_a" 2>/dev/null | sed -n 's/^_//p' | sort -u > "$native_symbols"
    sort -u "$MANAGED_SYMBOLS" | comm -12 - "$native_symbols" > "$present"
    echo "Managed entry points: $(sort -u "$MANAGED_SYMBOLS" | wc -l | tr -d ' ')," \
         "present in archive: $(wc -l < "$present" | tr -d ' ')"
    "$SCRIPT_DIR/generate-symbols-props.bash" "$present" "$OUT_DIR/OpenCvSharpExtern.symbols.props"
}

# --- Main ---
prepare_patched_sources

if [[ -z "$DEVICE_OPENCV_PREFIX" ]]; then
    DEVICE_OPENCV_PREFIX="$OUT_DIR/opencv-device"
    SIM_OPENCV_PREFIX="$OUT_DIR/opencv-simulator"
    build_opencv "device"    "$DEVICE_TOOLCHAIN" "$DEVICE_OPENCV_PREFIX"
    build_opencv "simulator" "$SIM_TOOLCHAIN"    "$SIM_OPENCV_PREFIX"
else
    echo "=== Reusing OpenCV prefixes: $DEVICE_OPENCV_PREFIX, $SIM_OPENCV_PREFIX ==="
fi

build_extern "device"    "$DEVICE_TOOLCHAIN" "$DEVICE_OPENCV_PREFIX"
build_extern "simulator" "$SIM_TOOLCHAIN"    "$SIM_OPENCV_PREFIX"

DEVICE_MERGED="$OUT_DIR/merged-device.a"
SIM_MERGED="$OUT_DIR/merged-simulator.a"
merge_static "$DEVICE_OPENCV_PREFIX" "$OUT_DIR/extern-device"    "$DEVICE_MERGED"
merge_static "$SIM_OPENCV_PREFIX"    "$OUT_DIR/extern-simulator" "$SIM_MERGED"
assemble_xcframework "$DEVICE_MERGED" "$SIM_MERGED"

if [[ -n "$MANAGED_SYMBOLS" ]]; then
    generate_symbols_props "$DEVICE_MERGED"
fi

echo ""
echo "=== Done ==="
echo "xcframework: $XCFRAMEWORK_OUT"
