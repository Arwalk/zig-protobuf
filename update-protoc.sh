PROTOC_VERSION=36.2

zig fetch --save=protoc-linux-x86_64 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip"
zig fetch --save=protoc-linux-x86_32 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_32.zip"
zig fetch --save=protoc-linux-s390 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-s390_64.zip"
zig fetch --save=protoc-linux-aarch_64 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-aarch_64.zip"
zig fetch --save=protoc-osx-aarch_64 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-osx-aarch_64.zip"
zig fetch --save=protoc-osx-x86_64 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-osx-x86_64.zip"
zig fetch --save=protoc-win64 "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-win64.zip"

# The sources for protobuf.protocFromSource. A new version may also need changes to the lists of
# source files and well-known protos in pkg/protoc/build.zig.
(cd pkg/protoc && zig fetch --save=protobuf "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protobuf-${PROTOC_VERSION}.zip")
