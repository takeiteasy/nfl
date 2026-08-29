## Plain Nim consuming a shimmed LFN library module -- no `lfn` CLI involved
## at import time, only at `lfn shim` generation time. See
## ../../../man/package-layout.md for the layout this exercises.
import mylib/util

doAssert quad(5) == 12
doAssert double(3) == 6
echo "package example ok"
