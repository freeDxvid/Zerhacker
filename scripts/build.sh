#!/bin/zsh
# Builds Zerhacker (universal binary), runs the Steinberg validator + offline test,
# and optionally installs the plug-in into ~/Library/Audio/Plug-Ins/VST3.
#
#   ./scripts/build.sh            build + test
#   ./scripts/build.sh --install  build + test + install
set -e
cd "$(dirname "$0")/.."

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j 8
ctest --test-dir build --output-on-failure

PLUGIN=build/VST3/Release/Zerhacker.vst3
codesign --force --deep -s - "$PLUGIN"
echo "Built: $PLUGIN"

if [[ "$1" == "--install" ]]; then
    mkdir -p ~/Library/Audio/Plug-Ins/VST3
    rm -rf ~/Library/Audio/Plug-Ins/VST3/Zerhacker.vst3
    cp -R "$PLUGIN" ~/Library/Audio/Plug-Ins/VST3/
    echo "Installed to ~/Library/Audio/Plug-Ins/VST3"
fi
