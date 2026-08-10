#!/bin/bash
GIT_BRANCH="release/9.0"
# OVERLAY: pin to the exact release/9.0 tip commit captured at packaging time
# (n9.0-2-g03d9533176) so every 9.0 artifact -- all licenses/platforms, desktop and
# android -- comes from ONE identical source tree, even as the release/9.0 branch keeps
# advancing. build.sh clones --branch=release/9.0 then `git checkout --detach` onto this.
GIT_COMMIT="03d9533176e98bb9fbf569c1f34968e73e948dd9"
