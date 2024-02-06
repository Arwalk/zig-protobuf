FROM mcr.microsoft.com/devcontainers/typescript-node:0-18
RUN git config --global core.autocrlf input

ADD . .

RUN bash ./install-zig.sh 0.12.0-dev.2613+0266017b5

ENV AGREE=true
