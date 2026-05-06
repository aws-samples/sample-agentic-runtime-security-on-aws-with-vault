#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -e

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
