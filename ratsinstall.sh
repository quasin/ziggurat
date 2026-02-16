#!/usr/bin/env bash

sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential git cmake
git clone --recursive https://github.com/librats/librats
cd librats
cmake -B build
make -C build
sudo make -C build install
