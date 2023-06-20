#!/usr/bin/env bash

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
	exit 1
fi

PROTOBUF_VERSION="23.2"

if [[ "$(uname)" == "Darwin" ]]
then
  PROTOBUF_OS="osx"
else
  PROTOBUF_OS="linux"
fi

if [[ "$(arch)" == "aarch64" ]]
then
  PROTOBUF_ZIP="protoc-${PROTOBUF_VERSION}-${PROTOBUF_OS}-aarch_64.zip"
else
  PROTOBUF_ZIP="protoc-${PROTOBUF_VERSION}-${PROTOBUF_OS}-x86_64.zip"
fi

# remove existing instalations
rm -rf /usr/local/lib/protobuf

# make sure /usr/local/lib/protobuf exists
mkdir -p /usr/local/lib/protobuf

curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/${PROTOBUF_ZIP}
unzip -o ${PROTOBUF_ZIP} -d /usr/local/lib/protobuf
rm $PROTOBUF_ZIP
chmod +x /usr/local/lib/protobuf/bin/protoc

rm /usr/local/bin/protoc || true

ln -s /usr/local/lib/protobuf/bin/protoc /usr/local/bin/protoc

echo "Done!"