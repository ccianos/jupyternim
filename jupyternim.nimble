# Package

version       = "0.5.0"
author        = "stisa"
description   = "A Jupyter Kernel for Nim"
license       = "MIT"

# Dependencies

requires "nim >= 1.0.0"
requires "zmq >= 0.3.1"
requires "hmac"
requires "nimSHA2"

srcDir = "src"

task dev, "Build a debug version":
  # Assumes cwd is jupyternim/
  var jnpath = gorgeEx("nimble path jupyternim")
  jnpath.output.stripLineEnd
  if jnpath.exitCode == 0:
    exec("nim c -d:debug -o:" & jnpath.output / bin[0].changeFileExt(ExeExt) & " src/jupyternim.nim")
  else:
    echo "Can't find an installed jupyternim"

task hcr, "Build a debug version with -d:useHcr":
  # Assumes cwd is jupyternim/
  var jnpath = gorgeEx("nimble path jupyternim")
  jnpath.output.stripLineEnd
  if jnpath.exitCode == 0:
    exec("nim c -d:debug -d:useHcr -o:" & jnpath.output / bin[0].changeFileExt(ExeExt) & " src/jupyternim.nim")
  else:
    echo "Can't find an installed jupyternim"
