FROM mcr.microsoft.com/devcontainers/typescript-node:0-18
RUN git config --global core.autocrlf input

ADD . .

RUN bash ./install-zig.sh 0.13.0

ENV AGREE=true
