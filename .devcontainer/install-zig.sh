#!/usr/bin/env bash


set -e
set -x

ZIG_VERSION=$1
echo "v" $ZIG_VERSION

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

check_packages ca-certificates xz-utils

# remove existing instalations
rm -rf /usr/local/lib/zig
# make sure /usr/local/lib/zig exists
mkdir -p /usr/local/lib/zig
# download binary, untar and ln into /usr/local/bin

ZIG_DOWNLOAD_URL=https://ziglang.org/download/$ZIG_VERSION/zig-linux-$(arch)-$ZIG_VERSION.tar.xz
case $ZIG_VERSION in
	*"+"*)
	ZIG_DOWNLOAD_URL=https://ziglang.org/builds/zig-linux-$(arch)-$ZIG_VERSION.tar.xz
	;;
esac

wget -c $ZIG_DOWNLOAD_URL -O - | tar -xJ --strip-components=1 -C /usr/local/lib/zig
# make binary executable
chmod +x /usr/local/lib/zig/zig
# create symbolic link
rm /usr/local/bin/zig || true
ln -s /usr/local/lib/zig/zig /usr/local/bin/zig

# install language server

LATEST_ZLS=$(curl https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json | /usr/bin/jq -r '.latest')

wget https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/$LATEST_ZLS/$ARCH-linux/zls

mv zls /usr/local/bin/zls

# make binary executable
chmod +x /usr/local/bin/zls

# Clean up
rm -rf /var/lib/apt/lists/*

echo "Done!"