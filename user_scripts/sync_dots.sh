#!/bin/bash

# Remove existing dusky directory
rm -rf $HOME/dusky/

# Clone the bare repository
git clone --bare --depth 1 https://github.com/T3rr0or/dusky.git $HOME/dusky

# Checkout the content to home directory
git --git-dir=$HOME/dusky/ --work-tree=$HOME checkout -f
