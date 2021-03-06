#!/usr/bin/env bash

set -euxo pipefail

# Github repository parameters
GITHUB_OWNER='Bitcoin-ABC'
GITHUB_REPO='bitcoin-abc'

# Max number of release versions to display
MAX_RELEASES=15

# Min version for rpc docs generation
MIN_VERSION_RPC_DOCS='0.22.1'

# Min version for man pages generation
MIN_VERSION_MAN_PAGES='0.22.1'

# jq must be installed
if ! command -v jq > /dev/null; then
  echo "Error: 'jq' is not installed."
  exit 10
fi


SCRIPT_DIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd)
TOPLEVEL=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

# Get the last MAX_RELEASES releases
RELEASES=$(curl -L -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases?per_page=${MAX_RELEASES})
echo "${RELEASES}" > "${TOPLEVEL}"/_data/github-releases.json

# Extract release version numbers
RELEASE_VERSIONS=($(echo ${RELEASES} | jq -r '[.[].name] | reverse[]'))

# Extract release tags
RELEASE_TAGS=($(echo ${RELEASES} | jq -r '[.[].tag_name] | reverse[]'))

# Create the cache directory as needed. This is where the sources will be
# cloned, and where the docs will be built.
: "${CACHE_DIR:=${TOPLEVEL}/.user-doc-cache}"
mkdir -p "${CACHE_DIR}"

SRC_DIR="${CACHE_DIR}/${GITHUB_REPO}"
if [ ! -d "${SRC_DIR}" ]
then
  git clone "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" "${SRC_DIR}"
fi

pushd "${SRC_DIR}"
git reset --hard HEAD
git clean -xffd || true
git checkout master
git pull --tags origin master
popd

version_greater_equal()
{
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

for i in "${!RELEASE_VERSIONS[@]}"
do
  VERSION="${RELEASE_VERSIONS[$i]}"
  TAG="${RELEASE_TAGS[$i]}"

  if version_greater_equal "${VERSION}" "${MIN_VERSION_RPC_DOCS}"
  then
    BUILD_RPC_DOCS="yes"
  else
    BUILD_RPC_DOCS="no"
  fi

  if version_greater_equal "${VERSION}" "${MIN_VERSION_MAN_PAGES}"
  then
    BUILD_MAN_PAGES="yes"
  else
    BUILD_MAN_PAGES="no"
  fi

  if [ "${BUILD_RPC_DOCS}" = "no" ] && [ "${BUILD_MAN_PAGES}" = "no" ]
  then
    continue
  fi

  # Checkout the release tag
  pushd "${SRC_DIR}"
  git checkout "tags/${TAG}"
  popd

  # Prepare some directories
  WEBSITE_DIR="${TOPLEVEL}/_doc/${VERSION}"
  mkdir -p "${WEBSITE_DIR}"

  VERSION_DIR="${CACHE_DIR}/${VERSION}"
  mkdir -p "${VERSION_DIR}"

  BUILD_DIR="${SRC_DIR}/build_${VERSION}"
  mkdir -p "${BUILD_DIR}"

  INSTALL_DIR="${BUILD_DIR}/install"
  mkdir -p "${INSTALL_DIR}"

  pushd "${BUILD_DIR}"

  if [ "${BUILD_RPC_DOCS}" = "yes" ] && [ ! -d "${VERSION_DIR}/rpc" ]
  then
    # Build and install the release version
    cmake -GNinja "${SRC_DIR}" -DCLIENT_VERSION_IS_RELEASE=ON -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"

    # Prior to version 0.22.2, the rpc-doc target required to manually spin a
    # regtest bitcoind server.
    if version_greater_equal "${VERSION}" "0.22.2"
    then
      ninja doc-rpc
    else
      # FIXME Remove the else branch after versions < 0.22.2 are obsolete
      (
        ninja install/strip

        BITCOIND_PID_FILE="${VERSION_DIR}/bitcoind_${VERSION}.pid"
        "${INSTALL_DIR}"/bin/bitcoind -regtest -daemon -pid="${BITCOIND_PID_FILE}"

        shutdown_bitcoind() {
          "${INSTALL_DIR}"/bin/bitcoin-cli -regtest stop > /dev/null 2>&1

          # Waiting for bitcoind shut down
          PID_WAIT_COUNT=0
          while [ -e "${BITCOIND_PID_FILE}" ]
          do
            : $((PID_WAIT_COUNT+=1))
            if [ "${PID_WAIT_COUNT}" -gt 20 ]
            then
              echo "Timed out waiting for bitcoind to stop"
              exit 3
            fi
            sleep 0.5
          done
        }
        trap "shutdown_bitcoind" EXIT

        # Waiting for bitcoind to spin up
        RPC_HELP_WAIT_COUNT=0
        while ! "${INSTALL_DIR}"/bin/bitcoin-cli -regtest help > /dev/null 2>&1
        do
          : $((RPC_HELP_WAIT_COUNT+=1))
          if [ "${RPC_HELP_WAIT_COUNT}" -gt 10 ]
          then
            echo "Timed out waiting for bitcoind to start"
            exit 2
          fi
          sleep 0.5
        done

        ninja doc-rpc
      )
    fi

    # Cache the result
    cp -R "${BUILD_DIR}/doc/rpc/en/${VERSION}/rpc" "${VERSION_DIR}/"
  fi

  if [ "${BUILD_MAN_PAGES}" = "yes" ] && [ ! -d "${VERSION_DIR}/man" ]
  then
    # xvfb is only needed to build headlessly.
    if ! command -v xvfb-run
    then
      echo "xvfb is required to build the docs headlessly, please install it."
      exit 3
    fi

    if [[ "${VERSION}" == "0.22.3" ]]; then
      # Cherry pick a fix to ensure the version number is set correctly
      git cherry-pick 6f59a8facadb99ffa0f64421d7248043de507c64
    fi

    # Build and install the man pages
    cmake -GNinja "${SRC_DIR}" -DCLIENT_VERSION_IS_RELEASE=ON -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
    # Version 0.22.4 calls xvfb-run and can cause a race, so force using a
    # single job.
    # FIXME Remove the -j1 once 0.22.4 gets obsoleted.
    xvfb-run -a -e /dev/stderr ninja -j1 install-manpages-html

    mkdir -p "${VERSION_DIR}/man"
    # Cache the result
    cp "${INSTALL_DIR}"/share/man/html/* "${VERSION_DIR}/man/"
  fi

  popd

  # Copy everything from the cache to the website directory
  cp -R "${VERSION_DIR}"/* "${WEBSITE_DIR}/"

done

# Pull all the markdown files from the ABC repository so they can be converted
# and rendered by jekyll. The tree directory structure is preserved in order to
# keep the links working.
pushd "${SRC_DIR}"
git checkout master
${SCRIPT_DIR}/fetch_markdown_files.sh "${SRC_DIR}"

# If the release notes file for the latest release isn't archived yet, make the
# latest release notes available for that version number. This temporary copy
# will be replaced once the release notes are archived.
ABC_MD_DOCS="${TOPLEVEL}"/abc_md_docs
LATEST_RELEASE_VERSION=${RELEASE_VERSIONS[${#RELEASE_VERSIONS[@]}-1]}
LATEST_RELEASE_NOTES="${ABC_MD_DOCS}/doc/release-notes/release-notes-${LATEST_RELEASE_VERSION}"
if [ ! -f "${LATEST_RELEASE_NOTES}.md" ]; then
  cp "${ABC_MD_DOCS}/doc/release-notes.md" "${LATEST_RELEASE_NOTES}.md"
  cp "${ABC_MD_DOCS}/doc/release-notes.page.md" "${LATEST_RELEASE_NOTES}.page.md"
  sed -i "s/permalink: \/doc\/release-notes.html/permalink: \/doc\/release-notes\/release-notes-${LATEST_RELEASE_VERSION}.html/g" "${LATEST_RELEASE_NOTES}.page.md"
fi
popd
