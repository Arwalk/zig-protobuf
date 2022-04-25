# zig-protobuf

-------

## This is WIP

This is an implementation of google Protocol Buffers version 3 in Zig.

Protocol Buffers is a serialization protocol so systems, from any programming language nor platform, can exchange data reliably.

Protobuf's strength lies in a generic codec paired with user-defined "messages" that will define the true nature of the data encoded.

Messages are usually mapped to a native language's structure/class definition thanks to a language-specific generator associated with an implementation.

Zig's compile-time evaluation becomes extremely strong and useful in this context: because the structure (a message) has to be known beforehand, the generic codec can leverage informations, at compile time, of the message and it's nature. This allows optimizations that are hard to get as easily in any other language, as Zig can mix compile-time informations with runtime-only data to optimize the encoding and decoding code paths.

## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

The current version of the zig compiler used for this project is 0.9.1.

### Encoding

- Scalar Value Types
    - [x] double
    - [x] float
    - [x] int32
    - [x] int64
    - [x] uint32
    - [x] uint64
    - [x] sint32
    - [x] sint64
    - [x] fixed32
    - [x] fixed64
    - [x] sfixed32
    - [x] sfixed64
    - [x] bool
    - [x] string / bytes
- [x] Enumerations
- [x] Submessages
- [x] Any
- [x] Oneof
- [x] Maps

### Decoding

- Scalar Value Types
    - [x] double
    - [x] float
    - [x] int32
    - [x] int64
    - [x] uint32
    - [x] uint64
    - [x] sint32
    - [x] sint64
    - [x] fixed32
    - [x] fixed64
    - [x] sfixed32
    - [x] sfixed64
    - [x] bool
    - [x] string / bytes
- [x] Enumerations
- [x] Submessages
- [x] Any
- [ ] Oneof **currently on hiatus to find a solution, focusing on generator**
- [x] Maps

### Code generator

- Scalar Value Types
    - [x] double
    - [x] float
    - [x] int32
    - [x] int64
    - [x] uint32
    - [x] uint64
    - [x] sint32
    - [x] sint64
    - [x] fixed32
    - [x] fixed64
    - [x] sfixed32
    - [x] sfixed64
    - [x] bool
    - [ ] string / bytes
- [ ] Enumerations
- [ ] Submessages
- [ ] Any
- [ ] Oneof
- [ ] Maps