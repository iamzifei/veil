#!/bin/bash
# The website lives in docs/ here but is SERVED from the jamesai.dev repo (iamzifei/home),
# because project Pages under this account inherit a different custom domain.
# Copies docs/ to <home>/veil/; commit and push the home repo to go live at https://jamesai.dev/veil/.
set -euo pipefail
HOME_REPO="${1:-$HOME/Dev/home}"
rsync -a --delete "$(cd "$(dirname "$0")/.." && pwd)/docs/" "$HOME_REPO/veil/"
echo "Synced → $HOME_REPO/veil/"
