import zmq, json, os, osproc, strutils, base64, streams
import ./messages, ./utils

type
  Heartbeat* = object
    socket*: TConnection
    alive: bool

  IOPub* = object
    socket*: TConnection
    key: string
    lastmsg: WireMessage #why?

  #TODO: encapsulate code better, why is stuff from shell exported?
  Shell* = object
    socket*: TConnection
    key: string    # session key
    pub*: IOPub     # keep a reference to pub so we can send status message
    count: Natural # Execution counter
    codecells: seq[string] # the cells sent to execute. TODO: only add the ones that compile?
    codeserver : Process # the codeserver process, needs to stay alive as long as we need to compile stuff

  Control* = object
    socket*: TConnection
    key: string
  
  Channels* = concept s
    s.socket is TConnection


# forward decl
proc updateCodeServer(shell: var Shell, firstInit=false): string


# Helpers that generally work on all channel objects
proc hasMsgs*(s: Channels): bool = getsockopt[int](s.socket, EVENTS) == 3
proc close*(s: Channels) = s.socket.close()
proc receiveMsg(s: Channels): WireMessage = decode(s.socket.recv_multipart)

proc sendMsg*(s: Channels, reply_type: string,
  content: JsonNode, key: string, parent: varargs[WireMessage]) =
  let encoded = encode(reply_type, content, key, parent)
  debug "Encoded ", reply_type
  s.socket.send_multipart(encoded)


## Heartbeat Socket
proc createHB*(ip: string, hbport: BiggestInt): Heartbeat =
  ## Create the heartbeat socket
  result.socket = zmq.listen("tcp://" & ip & ":" & $hbport)
  result.alive = true

proc beat*(hb: Heartbeat) =
  ## Execute the heartbeat loop.
  ## Usually ``spawn``ed to avoid killing the kernel when it's busy
  debug "starting hb loop..."
  while hb.alive:
    var s: string
    try:
      s = hb.socket.receive() # Read from socket
    except:
      debug "exception in Heartbeat Loop"
      break

    hb.socket.send(s) # Echo back what we read

proc close*(hb: var Heartbeat) =
  hb.alive = false
  hb.socket.close()

## IOPub Socket
proc createIOPub*(ip: string, port: BiggestInt, key: string): IOPub =
  ## Create the IOPub socket
# TODO: transport
  result.socket = zmq.listen("tcp://" & ip & ":" & $port, zmq.PUB)
  result.key = key

proc sendState*(pub: IOPub, state: string ) {.inline.} =
  pub.sendMsg("status", %* {"execution_state": state}, pub.key)

proc receive*(pub: IOPub) =
  ## Receive a message on the IOPub socket
  let recvdmsg: WireMessage = pub.receiveMsg()
  debug "pub received:\n", $recvdmsg


## Shell Socket
# TODO: move stuff related to codeserver somewhere else
const codeserver = staticRead("codeserver.nim")

when defined(windows):
  # TODO: This should probably be unique for each open server and
  #       same for all the files
  const outCodeServerName = "nimcodeserver.exe"
else:
  const outCodeServerName = "nimcodeserver"

const jnTempDir* = getHomeDir() / ".jupyternim"

# ORDER IS IMPORTANT 
const defaultFlags = ["--hotcodereloading:on", #"--nimcache:" & (jnTempDir).escape,
                      "-d:jupyter", 
                      "-d:release",
                      "--verbosity:0",
                      "-o:" & jnTempDir / outCodeServerName]

const initCodecells = [ staticRead("initialCodeCell.nim")]

var flags: seq[string] = @defaultFlags

when not defined(release):
  flags[^2] = "-d:debug" #switch release to debug for the compiled file too

proc writeCodeFile(codecells: openArray[string]) =
  ## Write out the file composed by the cells that were run until now.
  ## The last cell is wrapped in a proc so that it gets run by the codeserver
  ## and produces output. 
  var res = ""
  for i, cell in codecells:
    if i==codecells.len-1: # wrap the last cell in the hoist macro:
      res.add("hoist:\n")
      res.add(cell.indent(2) & "\n") # indent to avoid compilation errors
    else:
      res.add(cell & "\n")
  writeFile(jnTempDir / "codecells.nim", res)

proc startCodeServer(shell: var Shell): Process =
  ## Start the nimcodeserver process (the hcr main program)
  debug "confirm codeserver.exe exists: ", fileExists( jnTempDir / outCodeServerName)
  if not fileExists( jnTempDir / outCodeServerName):
    debug "forcing codeserver to be rebuilt and reinited"
    flags.add("-f") # maybe forcing a rebuild ?
    discard shell.updateCodeServer(firstInit=true)
    discard flags.pop()
  else:
    debug jnTempDir / outCodeServerName & " already exists"
  
  result = startProcess(jnTempDir / outCodeServerName)

proc updateCodeServer(shell: var Shell, firstInit=false): string =
  ## Write out the source code if firstInit==true, then
  ## write the code file (the "logic")
  ## compile it
  ## Returns the compiler output as a string
  if firstInit:
    debug "Write out codeserver"
    writeFile(jnTempDir/"codeserver.nim", codeserver) 
  
  debug "Write out codecells"
  writeCodeFile(shell.codecells)

  debug "Ensuring codeserver is alive"
  if not firstInit and not shell.codeserver.running:
    debug "The codeserver died, trying to restart it..."
    shell.codeserver = shell.startCodeServer()

  debug "Recompile codeserver to perform code reload"
  result = execProcess(r"nim c " & flatten(flags) & jnTempDir / "codeserver.nim") # compile the codeserver

proc createShell*(ip: string, shellport: BiggestInt, key: string,
    pub: IOPub): Shell =
  ## Create a shell socket
  result.socket = zmq.listen("tcp://" & ip & ":" & $shellport, zmq.ROUTER)
  result.key = key
  result.pub = pub
  # add the import to the codecells of shell, 
  # this way it will be there when generating the code to be run
  result.codecells = @initCodecells
  let tmp = result.updateCodeServer(firstInit=true)
  debug tmp
  result.codeserver = result.startCodeServer()

proc handleKernelInfo(s: Shell, m: WireMessage) =
  var content: JsonNode
  #echo "sending: Kernelinfo sending busy"
  content = %* {
    "protocol_version": "5.3",
    "implementation": "nim",
    "implementation_version": "0.4",
    "language_info": {
      "name": "nim",
      "version": NimVersion,
      "mimetype": "text/x-nim",
      "file_extension": ".nim",
    },
    "banner": ""
  }

  s.sendMsg("kernel_info_reply", content, s.key, m)

proc handleExecute(shell: var Shell, msg: WireMessage) =
  ## Handle the ``execute_request`` message
  inc shell.count
  let code = msg.content["code"].str # The code to be executed

  # TODO: move the logic that deals with magics and flags somewhere else
  if code.contains("#>flags"):  
    let 
      flagstart = code.find("#>flags")+"#>flags".len+1
      nwline = code.find("\u000A", flagstart)
      flagend = if nwline != -1: nwline else: code.len
    flags = code[flagstart..flagend].split()

  debug "with flags:", flags.flatten

  if code.contains("#>clear all") and dirExists(getHomeDir() / "inimtemp"):
    debug "Cleaning up..."
    flags = @defaultFlags
    removeDir(jnTempDir)
    createDir(jnTempDir)
    shell.codecells = @initCodecells #reset code
    let tmp = shell.updateCodeServer()
    debug tmp
    shell.codeserver = shell.startCodeServer

  # Send via iopub the block about to be executed
  var content = %* {
      "execution_count": shell.count,
      "code": code,
  }
  shell.pub.sendMsg("execute_input", content, shell.key, msg)

  # Compile and send compilation messages to jupyter's stdout
  shell.codecells.add(code)
  var compiler_out = shell.updateCodeServer()

  debug "file before:"
  debug readFile(jnTempDir / "codecells.nim")
  debug "file end"

  debug "server has data: ", shell.codeserver.hasData

  var status = "ok" # OR 'error'
  var std_type = "stdout"
  if compiler_out.contains("Error:"): 
    #TODO: ensure this can't appear in users code,
    #      maybe use outputcode of execProcess?
    status = "error"
    std_type = "stderr"
    #if shell.codeserver.running:
    #  shell.codeserver.kill()
    #shell.codeserver = startCodeServer(shell)
    # execution not ok, remove last cell
    debug "Compilation error, discarding last code cell"
    let discardedCell = shell.codecells.pop()
    debug "Discarded:" & discardedCell
    debug "file after:"
    debug readFile(jnTempDir / "codecells.nim")
    debug "file end"
  
  var compiler_lines = compiler_out.splitLines()
  
  # clean out empty lines from compilation messages
  compiler_out = ""
  for ln in compiler_lines:
    if ln != "": compiler_out &= (ln & "\n")

  content = %*{"name": std_type, "text": compiler_out}

  # Send compiler messages
  shell.pub.sendMsg("stream", content, shell.key, msg)

  if status == "error":
    content = %* { # TODO:
      "status": status,
      "ename": "Compile error", # Exception name, as a string
      "evalue": "Error", # Exception value, as a string
      "traceback": nil, # traceback frames as strings
    }
    shell.pub.sendMsg("error", content, shell.key, msg)
  else:
    # Since the compilation was fine, run code and send results with iopub

    # run the new code
    shell.codeserver.inputStream.writeLine("#runNimCodeServer")
    shell.codeserver.inputStream.flush
  
    debug "trying to read all...", shell.codeserver.hasData
    var exec_out: string
    var donewriting = false
    while not doneWriting:
      let tmp = shell.codeserver.outputStream.readLine
      if tmp.contains("#serverReplied"): 
        donewriting = true
        break # we dont want the last message anyway
      exec_out &= tmp & "\n"
    debug "done reading, read: ", exec_out

    content = %*{
        "execution_count": shell.count,
        "data": {"text/plain": exec_out}, # TODO: detect and handle other mimetypes
        "metadata": %*{}
    }
    shell.pub.sendMsg("execute_result", content, shell.key, msg)

  # Tell the frontend execution was ok, or not from shell
  if status == "error" or status == "abort":
    content = %* {
      "status": status,
      "execution_count": shell.count,
    }
  else:
    content = %* {
      "status": status,
      "execution_count": shell.count,
      "payload": {},
      "user_expressions": {},
    }
  shell.sendMsg("execution_reply", content, shell.key, msg)

proc parseNimsuggest(nims: string): tuple[found: bool, data: JsonNode] =
  # nimsuggest output is \t separated
  # http://nim-lang.org/docs/nimsuggest.html#parsing-nimsuggest-output
  discard

proc handleIntrospection(shell: Shell, msg: WireMessage) =
  let code = msg.content["code"].str
  let cpos = msg.content["cursor_pos"].num.int
  if code[cpos] == '.':
    discard # make a call to sug in nimsuggest sug <file> <line>:<pos>
  elif code[cpos] == '(':
    discard # make a call to con in nimsuggest con <file> <line>:<pos>
  # TODO: ask nimsuggest about the code
  var content = %* {
    "status": "ok", #or "error"
    "found": false, # found should be true if an object was found, false otherwise
    "data": {},     #TODO nimsuggest??
    "metadata": {},
  }
  shell.sendMsg("inspect_reply", content, shell.key, msg)

proc handleCompletion(shell: Shell, msg: WireMessage) =

  let code: string = msg.content["code"].str
  let cpos: int = msg.content["cursor_pos"].num.int

  let ws = "\n\r\t "
  let lf = "\n\r"
  var sw = cpos
  while sw > 0 and (not ws.contains(code[sw - 1])):
    sw -= 1
  var sl = sw
  while sl > 0 and (not lf.contains(code[sl - 1])):
    sl -= 1
  let wrd = code[sw..cpos]

  var matches: seq[string] = @[] # list of all matches

  # Snippets
  if "proc".startswith(wrd):
    matches &= ("proc name(arg: type): returnType = \n    #proc")
  elif "if".startswith(wrd):
    matches &= ("if (expression):\n    #then")
  elif "method".startswith(wrd):
    matches &= ("method name(arg: type): returnType = \n    #method")
  elif "iterator".startswith(wrd):
    matches &= ("iterator name(arg: type): returnType = \n    #iterator")
  elif "array".startswith(wrd):
    matches &= ("array[length, type]")
  elif "seq".startswith(wrd):
    matches &= ("seq[type]")
  elif "for".startswith(wrd):
    matches &= ("for index in iterable):\n  #for loop")
  elif "while".startswith(wrd):
    matches &= ("while(condition):\n  #while loop")
  elif "block".startswith(wrd):
    matches &= ("block name:\n  #block")
  elif "case".startswith(wrd):
    matches &= ("case variable:\nof value:\n  #then\nelse:\n  #else")
  elif "try".startswith(wrd):
    matches &= ("try:\n  #something\nexcept exception:\n  #handle exception")
  elif "template".startswith(wrd):
    matches &= ("template name (arg: type): returnType =\n  #template")
  elif "macro".startswith(wrd):
    matches &= ("macro name (arg: type): returnType =\n  #macro")

  # Single word matches
  let single = ["int", "float", "string", "addr", "and", "as", "asm", "atomic", "bind", "break", "cast",
                "concept", "const", "continue", "converter", "defer", "discard",
                "distinct", "div", "do",
                "elif", "else", "end", "enum", "except", "export", "finally",
                "for", "from", "func",
                "generic", "import", "in", "include", "interface", "is",
                "isnot", "let", "mixin", "mod",
                "nil", "not", "notin", "object", "of", "or", "out", "ptr",
                "raise", "ref", "return", "shl",
                "shr", "static", "tuple", "type", "using", "var", "when",
                "with", "without", "xor", "yield"]

  #magics = ['#>loadblock ','#>passflag ']

  # Add all matches to our list
  matches = matches & (filter(single) do (x: string) -> bool: x.startsWith(wrd))

  # TODO completion+nimsuggest

  var content = %* {
    # The list of all matches to the completion request
    "matches": matches,
    # The range of text that should be replaced by the above matches when a completion is accepted.
    # typically cursor_end is the same as cursor_pos in the request.
    "cursor_start": sw,
    "cursor_end": cpos,

    # Information that frontend plugins might use for extra display information about completions.
    "metadata": {},

    # status should be 'ok' unless an exception was raised during the request,
    # in which case it should be 'error', along with the usual error message content
    # in other messages. Currently assuming it won't error.
    "status": "ok"
  }
# debug msg
  shell.sendMsg("complete_reply", content, shell.key, msg)

proc handleHistory(shell: Shell, msg: WireMessage) =
  debug "Unhandled history"
  var content = %* {
    # A list of 3 tuples, either:
      # (session, line_number, input) or
      # (session, line_number, (input, output)),
      # depending on whether output was False or True, respectively.
    "history": [],
  }

proc handle(s: var Shell, m: WireMessage) =
  debug "shell: handle ", m.msg_type
  if m.msg_type == Kernel_Info:
    handleKernelInfo(s, m)
  elif m.msg_type == Execute:
    handleExecute(s, m)
  elif m.msg_type == Shutdown:
    debug "kernel wants to shutdown"
    quit()
  elif m.msg_type == Introspection: handleIntrospection(s, m)
  elif m.msg_type == Completion: handleCompletion(s, m)
  elif m.msg_type == History: handleHistory(s, m)
  else:
    debug "unhandled message: ", m.msg_type

proc receive*(shell: var Shell) =
  ## Receive a message on the shell socket, decode it and handle operations
  let recvdmsg: WireMessage = shell.receiveMsg()
  debug "shell: ", $recvdmsg.msg_type
  debug recvdmsg.content
  debug "end shell"
  shell.pub.sendState("busy")
  shell.handle(recvdmsg)
  shell.pub.sendState("idle")

proc close*(sl: var Shell) =
  sl.socket.close()
  sl.codeserver.terminate()


## Control socket
proc createControl*(ip: string, port: BiggestInt, key: string): Control =
  ## Create the control socket
  result.socket = zmq.listen("tcp://" & ip & ":" & $port, zmq.ROUTER)
  result.key = key

proc handle(c: Control, m: WireMessage) =
  if m.msg_type == Shutdown:
    #var content : JsonNode
    debug "shutdown requested"
    #content = %* { "restart": false }
    c.sendMsg("shutdown_reply", m.content, c.key, m)
    quit()
  #if m.msg_type ==

proc receive*(cont: Control) =
  ## Receive a message on the control socket and handle operations
  let recvdmsg: WireMessage = cont.receiveMsg()
  debug "received: ", $recvdmsg.msg_type
  cont.handle(recvdmsg)
