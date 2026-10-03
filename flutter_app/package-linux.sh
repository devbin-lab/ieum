#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
version=$(sed -n 's/^version: //p' pubspec.yaml | tr -d '\r')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
bundle=build/linux/x64/release/bundle
test -x "$bundle/ieum_flutter"
if find "$bundle" -type f | grep -E '\.(sqlite|db)(-wal|-shm)?$|project-preferences|demo-snapshot'; then
  echo 'Personal data must not be packaged' >&2
  exit 1
fi
mkdir -p dist/linux
cp linux/README-Linux.md "$bundle/README-Linux.md"
tar -czf dist/linux/Ieum-Linux-x64.tar.gz -C "$bundle" .
(cd dist/linux && sha256sum Ieum-Linux-x64.tar.gz > Ieum-Linux-x64.sha256)
