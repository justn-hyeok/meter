#!/bin/sh
# Builds one architecture slice and reports where the toolchain actually put it.
#
# The packaging scripts used to hardcode `<scratch>/<triple>/release`. A toolchain
# update moved the products to `<scratch>/out/Products/Release`, the old directory kept
# a months-old binary, and the release archives silently shipped that instead. Asking
# the toolchain removes the guess.

meter_build_slice() {
    product=$1
    arch=$2
    scratch=$3

    swift build -c release --product "$product" --arch "$arch" --scratch-path "$scratch" >&2
    swift build -c release --product "$product" --arch "$arch" --scratch-path "$scratch" --show-bin-path
}
