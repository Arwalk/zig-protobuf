FROM mcr.microsoft.com/devcontainers/typescript-node:0-18
RUN git config --global core.autocrlf input

ADD . .

RUN bash ./install-zig.sh 0.12.0-dev.389+61b70778b
RUN bash ./install-protoc.sh
ENV AGREE=true