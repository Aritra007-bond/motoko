#!/usr/bin/env bash

DRUN=${DRUN:-drun}
CONFIG=$(realpath $(dirname $0)/drun.toml)

#
# This script wraps drun to
#
# * extract the methods calls from comments in the second argument
#   (typically the test source files)
# * adds "ic:2A012B" as the destination to these calls
# * writes prometheus metrics to file descriptor 222
#   (for run.sh -p; post-processing happening in run.sh)
#


if [ -z "$1" ]
then
  echo "Usage: $0 <name>.wasm [call-script]"
  echo "or"
  echo "Usage: $0 <name>.drun"
  exit 1
fi

export LANG=C.UTF-8

# this could be used to delay drun to make it more deterministic, but
# it doesn't work reliably and slows down the test significantly.
# so until DFN-1269 fixes this properly, let's just not run
# affected tests on drun (only ic-ref-run).
EXTRA_BATCHES=1

if [ "${1: -5}" = ".drun" ]
then
  $DRUN -c "$CONFIG" --extra-batches $EXTRA_BATCHES $1
else
  ( echo "install ic:2A012B $1 0x"
    if [ -n "$2" ]
    then
      LANG=C perl -ne 'print "$1 ic:2A012B $2\n" if m,^//CALL (ingress|query) (.*),;print "upgrade ic:2A012B '"$1"' 0x\n" if m,^//CALL upgrade,; ' $2
    fi
  ) | $DRUN -c "$CONFIG" --extra-batches $EXTRA_BATCHES /dev/stdin
fi
