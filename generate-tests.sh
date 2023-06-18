#!/bin/bash

rm -rf tests/generated || true
mkdir -p tests/generated || true

protoc --plugin=zig-out/bin/protoc-gen-zig \
  --zig_out=tests/generated \
  -Itests/protos_for_test \
  --experimental_allow_proto3_optional \
  tests/protos_for_test/all.proto \
  tests/protos_for_test/whitespace-in-name.proto

zig fmt tests/generated

echo 'generate-tests.sh finished'