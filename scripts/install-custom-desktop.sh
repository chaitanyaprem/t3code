#!/usr/bin/env bash
# Builds the desktop app from this checkout and installs it over
# /Applications/T3 Code (Alpha).app, which runs on the live ~/.t3/userdata.
#
#   scripts/install-custom-desktop.sh                 build, then install
#   scripts/install-custom-desktop.sh --build-only    build and print the app path
#   scripts/install-custom-desktop.sh --install <app> install an already built app
#   scripts/install-custom-desktop.sh --build-version 0.0.46-preview.20261009.2
#
# The install step never quits the running app. It waits for you to quit it,
# backs up ~/.t3/userdata, moves the old app to the Trash, then copies and
# ad-hoc signs the new one.
set -euo pipefail

APP_NAME="T3 Code (Alpha).app"
INSTALLED_APP="/Applications/$APP_NAME"
USERDATA="$HOME/.t3/userdata"
# Written into the bundle so the next run can refuse to install a build that
# lacks the commit the installed app last ran the database with.
COMMIT_MARKER="Contents/Resources/t3code-custom-commit"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

mode="all"
built_app=""
build_version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) mode="build" ;;
    --install)
      mode="install"
      built_app="${2:?--install needs the path to a built app}"
      shift
      ;;
    --build-version)
      build_version="${2:?--build-version needs a value}"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
  shift
done

installed_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true
}

# <next patch of the repo version>-preview.<today>.<n>. Only `-preview.`
# versions ship without an update feed, so anything else would let the app
# update itself back to upstream.
default_build_version() {
  local repo_version base today installed run
  repo_version="$(node -p "require('./apps/server/package.json').version")"
  base="${repo_version%.*}.$((${repo_version##*.} + 1))"
  today="$(date +%Y%m%d)"
  installed="$(installed_version)"
  run=1
  if [[ "$installed" == "$base-preview.$today."* ]]; then
    run=$((${installed##*.} + 1))
  fi
  echo "$base-preview.$today.$run"
}

build() {
  if ! git diff --quiet HEAD; then
    echo "Tracked files have uncommitted changes. Commit them first: the installed app records HEAD as its commit." >&2
    exit 1
  fi
  # Database migrations come from upstream, and rebasing rewrites the custom
  # commits, so compare the upstream commit each build sits on.
  local installed_commit installed_base
  if [ -f "$INSTALLED_APP/$COMMIT_MARKER" ]; then
    installed_commit="$(cat "$INSTALLED_APP/$COMMIT_MARKER")"
    if ! installed_base="$(git merge-base "$installed_commit" upstream/main)"; then
      echo "Cannot find $installed_commit, the installed app's commit, relative to upstream/main. Run git fetch upstream." >&2
      exit 1
    fi
    if ! git merge-base --is-ancestor "$installed_base" HEAD; then
      echo "HEAD is based on older upstream code than the installed app ($installed_base)." >&2
      echo "Installing this build could run older code on a newer database. Rebase onto upstream/main first." >&2
      exit 1
    fi
  fi

  if [ -z "$build_version" ]; then
    build_version="$(default_build_version)"
  fi
  if [[ ! "$build_version" =~ -preview\.[0-9]{8}\.[0-9]+$ ]]; then
    echo "Build version must end in -preview.<yyyymmdd>.<n>, got: $build_version" >&2
    exit 64
  fi

  export PATH="$HOME/.local/share/vite-plus/bin:$PATH"
  # The native resource monitor needs Rust 1.95.
  export RUSTUP_TOOLCHAIN=1.95.0

  # The build keeps its stage in a temp directory. Giving it a private TMPDIR
  # makes the stage findable without parsing build output.
  local stage_parent
  stage_parent="$(mktemp -d "${TMPDIR:-/tmp}/t3code-custom-build.XXXXXX")"
  echo "Building $build_version from $(git rev-parse --short HEAD) (stage under $stage_parent)" >&2

  # electron-builder exits 1 writing update metadata when there is no publish
  # config, after the app is already built. Judge the build by the app.
  TMPDIR="$stage_parent" vp run dist:desktop:dmg --build-version "$build_version" --keep-stage >&2 || true

  local candidate
  for candidate in "$stage_parent"/t3code-desktop-mac-stage-*/app/dist/mac-arm64/"$APP_NAME"; do
    if [ -d "$candidate" ]; then
      built_app="$candidate"
    fi
  done
  if [ -z "$built_app" ]; then
    echo "Build produced no app under $stage_parent." >&2
    exit 1
  fi
  git rev-parse HEAD >"$built_app/$COMMIT_MARKER"
  echo "Built: $built_app" >&2
}

app_is_running() {
  # Only a command that starts with the bundle path counts, helpers included.
  # A plain substring match also hits any shell or grep that merely mentions
  # the path in its arguments.
  local command
  while IFS= read -r command; do
    if [[ "$command" == "$INSTALLED_APP/Contents/"* ]]; then
      return 0
    fi
  done < <(ps -axo command=)
  return 1
}

install() {
  if [ ! -d "$built_app/Contents" ]; then
    echo "Not an app bundle: $built_app" >&2
    exit 1
  fi
  while app_is_running; do
    if [ ! -t 0 ]; then
      echo "T3 Code (Alpha) is running. Quit it, then run:" >&2
      echo "  scripts/install-custom-desktop.sh --install \"$built_app\"" >&2
      exit 2
    fi
    read -r -p "T3 Code (Alpha) is running. Quit it, then press Enter. " _
  done

  local stamp
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  if [ -d "$USERDATA" ]; then
    local backup="$HOME/t3-userdata-backup-$stamp"
    cp -Rp "$USERDATA" "$backup"
    echo "Backed up userdata to $backup" >&2
  fi
  if [ -e "$INSTALLED_APP" ]; then
    mv "$INSTALLED_APP" "$HOME/.Trash/${APP_NAME%.app} $stamp.app"
  fi
  ditto "$built_app" "$INSTALLED_APP"
  # Without the ad-hoc signature the app will not launch on Apple Silicon.
  codesign --force --deep --sign - "$INSTALLED_APP"
  echo "Installed $(installed_version) at $INSTALLED_APP" >&2
}

case "$mode" in
  all)
    build
    install
    ;;
  build)
    build
    echo "$built_app"
    ;;
  install)
    install
    ;;
esac
