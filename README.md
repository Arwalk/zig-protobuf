# zig-protobuf

-------

## Welcome!

This is an implementation of google Protocol Buffers version 3 in Zig.

Protocol Buffers is a serialization protocol so systems, from any programming language nor platform, can exchange data reliably.

Protobuf's strength lies in a generic codec paired with user-defined "messages" that will define the true nature of the data encoded.

Messages are usually mapped to a native language's structure/class definition thanks to a language-specific generator associated with an implementation.

Zig's compile-time evaluation becomes extremely strong and useful in this context: because the structure (a message) has to be known beforehand, the generic codec can leverage informations, at compile time, of the message and it's nature. This allows optimizations that are hard to get as easily in any other language, as Zig can mix compile-time informations with runtime-only data to optimize the encoding and decoding code paths.

## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

The latest version of the zig compiler used for this project is 0.12.0-dev.293+f33bb0228.

This project is currently able to handle all scalar types for encoding, decoding, and generation through the plugin.


## How to use

Start by building the generator with `zig build install`. This will generate `zig-out/bin/protoc-gen-zig`. This executable is the `protoc` plugin that will allow you to generate zig code from `.proto` message files using `protoc --plugin=zig-out/bin/protoc-gen-zig my_message_file.proto`.

You can now use your newly generated files with the library implementation in `src/protobuf.zig`.

