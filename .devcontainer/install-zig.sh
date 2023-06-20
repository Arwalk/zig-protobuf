#!/usr/bin/env bash

ZIG_VERSION="${VERSION:-"master"}"

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
	exit 1
fi

# Clean up
rm -rf /var/lib/apt/lists/*

ARCH="$(uname -m)"

# Checks if packages are installed and installs them if not
check_packages() {
	if ! dpkg -s "$@" >/dev/null 2>&1; then
		if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
			echo "Running apt-get update..."
			apt-get update -y
		fi
		apt-get -y install --no-install-recommends "$@"
	fi
}

# make sure we have curl and jq
check_packages ca-certificates curl xz-utils jq binutils-dev libssl-dev libcurl4-openssl-dev zlib1g-dev libdw-dev libiberty-dev

# remove existing instalations
rm -rf /usr/local/lib/zig

# make sure /usr/local/lib/zig exists
mkdir -p /usr/local/lib/zig

INDEX_URL="https://ziglang.org/download/index.json"

if [[ "$ZIG_VERSION" == "latest" || "$ZIG_VERSION" == "current" || "$ZIG_VERSION" == "lts" ]]
then
	# for latest we download the latest *release* version
	DOWNLOAD_URL=$(curl -sSL $INDEX_URL | jq -r 'to_entries[1].value."'"$ARCH"'-linux".tarball')
else
	DOWNLOAD_URL=$(curl -sSL $INDEX_URL | jq -r '."'"$ZIG_VERSION"'"."'"$ARCH"'-linux".tarball')
fi

# download binary, untar and ln into /usr/local/bin
curl -sSL $DOWNLOAD_URL | tar xJ -C /usr/local/lib/zig --strip-components 1
chmod +x /usr/local/lib/zig/zig

rm /usr/local/bin/zig || true

ln -s /usr/local/lib/zig/zig /usr/local/bin/zig

# Clean up
rm -rf /var/lib/apt/lists/*

echo "Done!"