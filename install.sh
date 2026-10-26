#!/bin/sh
set -eu
native_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${WINDOW_FACTORY_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/window-factory/build}
exec mise exec -- node "$native_root/scripts/install.cjs" --source "$output/Window Factory.app" "$@"
