#!/bin/bash

set -ex

pushd ~/.workstation
git switch ode
git pull
./setup.sh
git switch -
popd

