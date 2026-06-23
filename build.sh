#!/usr/bin/env bash

darklua process ./main.luau ./bundled.luau || exit 1
lune build ./bundled.luau -o ./suds || exit
