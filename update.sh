#!/bin/bash

set -ex

pushd ~/.workstation
git switch gusto
git pull
./setup.sh
git switch -
popd

