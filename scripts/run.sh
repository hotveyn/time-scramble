#!/bin/sh
# Сборка и запуск с логами в терминале (Ctrl+C — остановить)
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
exec build/Build/Products/Debug/time-scramble.app/Contents/MacOS/time-scramble
