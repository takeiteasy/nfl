import lisp

let stdContent = readFile("std/nil.nil")
let nimCode = transpileNoStdlib(stdContent)
writeFile("std/nil.nim", nimCode)
echo "Built std/nil.nim"
