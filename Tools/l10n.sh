#!/bin/sh
# Usage: Tools/l10n.sh generate | validate --require cs-CZ   (run from the repository root)
set -e
exec swift run -q --package-path Tools/L10n l10n "$@"
