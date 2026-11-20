#!/bin/sh
# Makes the single-file installer a release carries: install.sh with the two scripts it installs
# inside it, so it can be fetched and run without the rest of the repository.
#   scripts/car-mode/build-installer.sh > install-car-mode.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)

embed() {
  # The end marker can't occur in the scripts, which the test checks.
  printf '    %s) cat <<'"'"'NOTHERING_EMBEDDED_SCRIPT'"'"'\n' "$1"
  cat "$here/$1"
  printf 'NOTHERING_EMBEDDED_SCRIPT\n      ;;\n'
}

while IFS= read -r line; do
  if [ "$line" = "# EMBEDDED SCRIPTS" ]; then
    echo 'EMBEDDED=1'
    echo 'embedded() {'
    echo '  case "$1" in'
    embed offline-network.sh
    embed car-watch.sh
    echo '  esac'
    echo '}'
  else
    printf '%s\n' "$line"
  fi
done < "$here/install.sh"
