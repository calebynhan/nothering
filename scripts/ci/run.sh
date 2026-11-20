#!/bin/bash
# Builds and tests everything the direct link touches, on a Mac with Xcode and Tuist:
#   scripts/ci/run.sh [version]
# Every step runs even after one failed, so one run shows every error. Each step's whole output is
# out/logs/<step>.log, its errors are out/logs/<step>.errors.txt, and out/summary.txt has one line
# per step. With the iPhone app and the Mac tool built, out/release/ holds what a release carries.
set -u
version=${1:-}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
out=$root/out
logs=$out/logs
derived=$root/.build-ci
rm -rf "${out:?}"
mkdir -p "$logs"
: > "$out/summary.txt"
failed=""

build_number=$(git rev-list --count HEAD)
if [[ -z $version ]]; then
  # Not a release: a version that says so, and still tells builds apart.
  version=0.0.$build_number
elif ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::the version is x.y.z, not '$version'"
  exit 2
fi
{
  echo "commit: $(git rev-parse HEAD)"
  echo "version: $version ($build_number)"
  echo "xcode: $(xcodebuild -version 2>&1 | tr '\n' ' ')"
  echo "macOS: $(sw_vers -productVersion 2>&1)"
} >> "$out/summary.txt"

# No index for the editor, and nothing signed: the tests need no signature and the iPhone app is
# signed by whoever installs it.
flags=(COMPILER_INDEX_STORE_ENABLE=NO)
unsigned=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)

# The lines of a log that say what went wrong, and for compile errors a note GitHub shows on the file.
errors_of() {
  local log=$logs/$1.log errors=$logs/$1.errors.txt
  grep -E "error:|✘ |recorded an issue|Test Case .* failed|\*\* [A-Z ]+ FAILED \*\*|fatal error|Undefined symbols|ld: |FAILED:" "$log" | sort -u | head -300 > "$errors"
  sed -n -E "s|^$root/([^:]+):([0-9]+):[0-9]+: error: (.*)|::error file=\1,line=\2::\3|p" "$log" | sort -u | head -50
}

# step <name> <command...>
step() {
  local name=$1 start=$SECONDS result
  shift
  echo "::group::$name"
  if "$@" > "$logs/$name.log" 2>&1; then
    result=ok
  else
    result=FAILED
    failed="$failed $name"
  fi
  echo "$name: $result ($((SECONDS - start)) s)" | tee -a "$out/summary.txt"
  errors_of "$name"
  if [[ $result == FAILED ]]; then
    cat "$logs/$name.errors.txt"
    echo "the end of $logs/$name.log:"
    tail -40 "$logs/$name.log"
  fi
  echo "::endgroup::"
  [[ $result == ok ]]
}

xcode() {
  xcodebuild -workspace Nothering.xcworkspace -derivedDataPath "$derived" "$@" "${flags[@]}"
}

step car-mode-scripts sh scripts/car-mode/test.sh
step direct-scripts sh scripts/direct/test.sh
if step generate env TUIST_BUILD_NUMBER="$build_number" tuist generate --no-open; then
  step test-ProxyCore xcode test -scheme ProxyCore -configuration Debug -destination platform=macOS "${unsigned[@]}"
  step test-PhoneLink xcode test -scheme PhoneLink -configuration Debug -destination platform=macOS "${unsigned[@]}"
  # A bundle ID and name of its own, so it installs next to the App Store's Nothering.
  step build-iphone-app xcode build -scheme NotheringiOS -configuration Production \
    -destination generic/platform=iOS "${unsigned[@]}" BUNDLE_ID_PREFIX=app.nothering.direct
  iphone=$?
  # For both kinds of Mac, and signed by nobody in particular, which is all a tool run from a
  # terminal needs.
  step build-mac-tool xcode build -scheme NotheringMac -configuration Production \
    -destination generic/platform=macOS ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
  tool=$?
  # Only to see it compile: without a paid account's signature macOS won't load its extension.
  step build-mac-app xcode build -scheme NotheringMenuBar -configuration Debug -destination platform=macOS "${unsigned[@]}"
  if [[ $iphone -eq 0 && $tool -eq 0 ]]; then
    step package scripts/ci/package.sh "$version" "$build_number" "$derived" "$out/release"
  else
    echo "package: skipped, it needs the iPhone app and the Mac tool" | tee -a "$out/summary.txt"
  fi
fi

if [[ -n $failed ]]; then
  echo "failed:$failed" | tee -a "$out/summary.txt"
  exit 1
fi
echo "all steps passed" | tee -a "$out/summary.txt"
