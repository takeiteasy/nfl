import lisp

let stdContent = readFile("std/nilpkg.nil")
let nimCode = transpileNoStdlib(stdContent)
writeFile("std/nilpkg.nim", nimCode)
echo "Built std/nilpkg.nim"
