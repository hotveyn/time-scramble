#!/bin/sh
# Сборка time-scramble (Debug) в ./build
set -eu
cd "$(dirname "$0")/.."
xcodebuild -scheme time-scramble -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build -quiet build
