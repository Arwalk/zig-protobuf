#!/bin/bash

rm -rf tests/generated || true
mkdir -p tests/generated || true

protoc --plugin=zig-out/bin/protoc-gen-zig \
  --zig_out=tests/generated \
  -Itests/protos_for_test \
  --experimental_allow_proto3_optional \
  tests/protos_for_test/all.proto \
  tests/protos_for_test/whitespace-in-name.proto

zig fmt tests/generated/tests.pb.zig
zig fmt tests/generated/vector_tile.pb.zig
zig fmt tests/generated/jspb/test.pb.zig
zig fmt tests/generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig
zig fmt tests/generated/google/protobuf.pb.zig

echo 'generate-tests.sh finished'