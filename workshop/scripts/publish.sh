#!/bin/bash

# Script to publish workshop to Workshop Studio
# Usage: ./scripts/publish.sh <version>
# Example: ./scripts/publish.sh 1.0.0

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -e

# Check if version is provided
if [ -z "$1" ]; then
  echo "Error: Version is required"
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.0"
  exit 1
fi

VERSION="$1"
echo "Publishing with version: $VERSION"

# Workshop Studio asset bucket prefix for this workshop
asset_bucket_prefix='agentic-runtime-security-aws'
ASSET_FILE="labs-${VERSION}.zip"

echo "Checking if version already exists..."
if aws s3 ls "s3://ws-assets-us-east-1/$asset_bucket_prefix/$ASSET_FILE" 2>/dev/null; then
  echo "Error: Version $VERSION already exists in S3"
  echo "Found: s3://ws-assets-us-east-1/$asset_bucket_prefix/$ASSET_FILE"
  echo "Please use a different version number"
  exit 1
fi

git_remote_name='codecommit'

echo "Running pre-flight checks..."

exit_code=0

yarn check > /dev/null || exit_code=$?

if [ $exit_code -gt 0 ]; then
  echo "Error: You need to run 'yarn install'"
  exit 1
fi

git update-index --refresh

git diff-index HEAD -- || exit_code=$?

if [ $exit_code -gt 0 ]; then
  echo "Error: There appears to be uncommitted changes in your repository"
  echo "Make sure to commit or revert all changes"
  exit 1
fi

git ls-remote --exit-code $git_remote_name > /dev/null || exit_code=$?

if [ $exit_code -gt 0 ]; then
  echo "Error: Failed checking Workshop Studio CodeCommit"
  echo "Make sure you have a remote named '$git_remote_name' and you have obtained credentials from Workshop Studio"
  exit 1
fi

echo "Packaging assets..."

bash $SCRIPT_DIR/package-assets.sh publish "$VERSION"

git update-index --refresh

git diff-index HEAD -- || exit_code=$?

if [ $exit_code -gt 0 ]; then
  echo "Error: There are uncommitted changes after packaging"
  echo "Please commit changes before running this script again"
  exit 1
fi

echo "Syncing assets..."

aws s3 sync ./assets s3://ws-assets-us-east-1/$asset_bucket_prefix --delete

echo "Pushing to CodeCommit..."

git push codecommit mainline > /dev/null

echo ""
echo "=========================================="
echo "IMPORTANT REMINDER"
echo "=========================================="
echo ""
echo "DON'T FORGET TO SYNC THE ASSETS"
echo "DIRECTLY IN WORKSHOP STUDIO!"
echo ""
echo "Go to Workshop Studio and manually"
echo "sync the asset directory to complete"
echo "the deployment process."
echo ""
echo "=========================================="

unset ASSET_VERSION
