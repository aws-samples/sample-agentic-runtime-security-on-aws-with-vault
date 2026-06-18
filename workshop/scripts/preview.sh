#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -e

# Always re-sync assets/ -> workshop/static/images/ before serving the preview.
# The destination directory is gitignored, so without this step a freshly added
# diagram in assets/ (e.g. ivia-stack.svg landed 2026-05-25) would silently 404
# in the local preview while every Workshop Studio CDN copy worked fine.
bash "$SCRIPT_DIR/package-assets.sh"

if [ ! -f "$SCRIPT_DIR/../tmp/preview_build" ]; then
  echo "Download Workshop Studio preview utility..."

  operating_system=$(uname)

  preview_utility_url='https://artifacts.us-east-1.prod.workshops.aws/v2/cli/linux/preview_build'

  if [[ "$operating_system" == 'Darwin' ]]; then
    if [[ $(uname -m) == 'arm64' ]]; then
      preview_utility_url='https://artifacts.us-east-1.prod.workshops.aws/v2/cli/osx_arm/preview_build'
    else
      preview_utility_url='https://artifacts.us-east-1.prod.workshops.aws/v2/cli/osx/preview_build'
    fi
  fi

  mkdir -p $SCRIPT_DIR/../tmp

  curl -s -o $SCRIPT_DIR/../tmp/preview_build $preview_utility_url

  chmod +x $SCRIPT_DIR/../tmp/preview_build
fi

(cd $SCRIPT_DIR/.. && tmp/preview_build)
