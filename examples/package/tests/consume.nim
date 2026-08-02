## Plain Nim consuming a shimmed NFL library module -- no `nfl` CLI involved
## at import time, only at `nfl shim` generation time. See
## ../../../man/package-layout.md for the layout this exercises.
import mylib/util

doAssert quad(5) == 12
doAssert double(3) == 6
echo "package example ok"
