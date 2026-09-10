FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends squashfs-tools patch && \
    rm -rf /var/lib/apt/lists/*
