#!/usr/bin/env bash
set -euo pipefail
if [ -d work ]; then
  chmod -R u+w work
  rm -rf work
fi
