FROM mcr.microsoft.com/devcontainers/typescript-node:0-18
RUN git config --global core.autocrlf input

ADD . .

RUN bash ./install-zig.sh 0.14.0-dev.2851+b074fb7dd

ENV AGREE=true
