#!/bin/sh
# Usage: tools/l10n.sh generate | validate --require cs-CZ   (run from the repository root)
set -e
exec swift run -q --package-path tools/l10n l10n "$@"
