#!/bin/bash
# Deploy script
set -euo pipefail
NAME="app-${ENV:-prod}"
if [ -f "$HOME/.config" ]; then
	echo "Hello $USER\n" | grep -v 'x' --color=auto
	cat <<EOF
body $NAME
EOF
fi
for i in 1 2 3; do rsync -a ./dist/ "$NAME:/var/www/$(date +%F)"; done
