FROM mcr.microsoft.com/devcontainers/typescript-node:0-18
ADD . .
RUN bash ./install-zig.sh
RUN bash ./install-protoc.sh
ENV AGREE=true
