#!/bin/bash

zig build

rm -rf bootstrapped-generator/google
mkdir -p bootstrapped-generator/google || true

protoc --plugin=zig-out/bin/protoc-gen-zig \
  --zig_out=bootstrapped-generator \
  /usr/local/lib/protobuf/include/google/protobuf/compiler/plugin.proto \
  /usr/local/lib/protobuf/include/google/protobuf/descriptor.proto

zig fmt bootstrapped-generator

echo 'generation finished'