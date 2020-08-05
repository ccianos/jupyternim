import zmq, json, os, osproc, strutils, base64, streams, tables
import ./messages, ./utils

type
  Heartbeat* = object
    socket*: TConnection
    alive: bool

  IOPub* = object
    socket*: TConnection
    lastmsg: WireMessage #why?

  #TODO: encapsulate code better, why is stuff from shell exported?
  Shell* = object
    socket*: TConnection
    pub*: IOPub     # keep a reference to pub so we can send status message
    count: Natural # Execution counter
    code: OrderedTable[string, string] # hold the code for cells that compile as a cellId:code table
    codeserver : Process # the codeserver process, needs to stay alive as long as we need to compile stuff
    executingCellId: string # id of the executing cell id

  Control* = object
    socket*: TConnection
  
  Channels* = concept s
    s.socket is TConnection


# forward decl
proc updateCodeServer(shell: var Shell, firstInit=false): tuple[output: string, exitcode: int]


# Helpers that generally work on all channel objects
proc hasMsgs*(s: Channels): bool = getsockopt[int](s.socket, EVENTS) == 3
proc close*(s: Channels) = s.socket.close()
proc receiveMsg(s: Channels): WireMessage = decode(s.socket.recv_multipart)

proc sendMsg*(s: Channels, reply_type: WireType,
  content: JsonNode, parent: varargs[WireMessage]) =
  let encoded = encode(reply_type, content, parent)
  debug "Encoded ", reply_type
  s.socket.send_multipart(encoded)


## Heartbeat Socket
proc createHB*(ip: string, hbport: BiggestInt): Heartbeat =
  ## Create the heartbeat socket
  result.socket = zmq.listen("tcp://" & ip & ":" & $hbport, zmq.REP)
  result.alive = true


proc close*(hb: var Heartbeat) =
  hb.alive = false
  hb.socket.close()

## IOPub Socket
proc createIOPub*(ip: string, port: BiggestInt): IOPub =
  ## Create the IOPub socket
# TODO: transport
  result.socket = zmq.listen("tcp://" & ip & ":" & $port, zmq.PUB)

proc sendState*(pub: IOPub, state: string, parent:varargs[WireMessage] ) {.inline.} =
  if len(parent) != 0:
    pub.sendMsg(status, %* {"execution_state": state}, parent[0])
  else:
    pub.sendMsg(status, %* {"execution_state": state})

proc receive*(pub: IOPub) =
  ## Receive a message on the IOPub socket
  let recvdmsg: WireMessage = pub.receiveMsg()
  #debug "pub received:\n", $recvdmsg


## Shell Socket

var useHcr: bool = false # Hcr is highly experimental

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
const defaultFlags = ["", # for HCR
                      "-d:release",
                      "--verbosity:0",
                      "--hint[Processing]:off"]
                      

const requiredFlags = ["-d:jupyter", "-o:" & jnTempDir / outCodeServerName]

when defined useHcr:
  const initialCodecell = staticRead("initialCodeCell.nim")
else:
  const initialCodecell = "discard \"Generated by JupyterNim\""

var flags: seq[string] = @defaultFlags

when not defined(release):
  flags[1] = "-d:debug" #switch release to debug for the compiled file too
  flags[2] = ""#"--verbosity:3" # remove verbosity:0 flag

when defined useHcr:
  flags[0] = "--hotcodereloading:on" # enable hotcodereloading

proc writeCodeFile(shell:Shell) =
  ## Write out the file composed by the cells that were run until now.
  ## The last cell is wrapped in a proc so that it gets run by the codeserver
  ## and produces output. 
  var res = ""
  for k, cell in shell.code:
    if k == shell.executingCellId:
      # save the lastmsg to a string in case we want to use it in display
      #res.add("jnparentmsg = " & ($(%* shell.pub.lastmsg)).escapeJson) #omg the json escaping
      when defined useHcr:
        # wrap the last cell in the hoist macro:
        res.add("hoist:\n")
        res.add(cell.indent(2) & "\n") # indent to avoid compilation errors
      else:
        res.add("\necho \"#>newcodeout\"\n") # so that we can cut out unneeded outputs
        res.add(cell & "\n") 
      break # we don't need all the file if just changing one line
    else:
      res.add(cell & "\n")
  writeFile(jnTempDir / "codecells.nim", res)

proc startCodeServer(shell: var Shell): Process =
  ## Start the nimcodeserver process (the hcr main program)
  debug "HCR: confirm codeserver.exe exists: ", fileExists( jnTempDir / outCodeServerName)
  if not fileExists( jnTempDir / outCodeServerName):
    debug "forcing codeserver to be rebuilt and reinited"
    flags.add("-f") # maybe forcing a rebuild ?
    discard shell.updateCodeServer(firstInit=true)
    discard flags.pop()
  else:
    debug jnTempDir / outCodeServerName & " already exists"
  
  result = startProcess(jnTempDir / outCodeServerName)

proc updateCodeServer(shell: var Shell, firstInit=false): tuple[output: string, exitcode: int] =
  ## Write out the source code if firstInit==true, then
  ## write the code file (the "logic")
  ## compile it
  ## Returns the compiler output as a string
  if firstInit:
    debug "Write out codeserver"
    writeFile(jnTempDir/"codeserver.nim", codeserver) 
  
  debug "Write out codecells"
  writeCodeFile(shell)

  when defined useHcr:
    debug "Ensuring codeserver is alive"
    if not firstInit and not shell.codeserver.running:
      debug "The codeserver died, trying to restart it..."
      shell.codeserver = shell.startCodeServer()

  debug "Recompile codeserver"
  when defined useHcr:
    result = execCmdEx(r"nim c " & flatten(flags) & flatten(requiredFlags) & jnTempDir / "codeserver.nim") # compile the codeserver
  else:
    result = execCmdEx(r"nim c " & flatten(flags) & flatten(requiredFlags) & jnTempDir / "codecells.nim") # compile the codeserver

proc createShell*(ip: string, shellport: BiggestInt, pub: IOPub): Shell =
  ## Create a shell socket
  #debug "shell at ", ip, " ", shellport
  result.socket = zmq.listen("tcp://" & ip & ":" & $shellport, zmq.ROUTER)
  result.pub = pub
  # add the import to the codecells of shell, 
  # this way it will be there when generating the code to be run
  result.code = initOrderedTable[string, string]()
  result.code["initialCell"] = initialCodecell
  when defined useHcr:
    let tmp = result.updateCodeServer(firstInit=true)
    debug tmp.output
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

  s.sendMsg(kernel_info_reply, content, m)

const MagicsStrings = ["#>flags", "#>clear all"]
#[TODO: find an efficient way to do the following
        (since it's unlikely that a lot of flags are present, looping all lines is not a good idea)
proc handleMagics(codeseq: seq[string])
  for line in codeseq:
    if line.startsWith(MagicsStrings[0]):
      flags = code[MagicsStrings[0].len+1..^1].split()
      debug "with custom flags:", flags.flatten
    elif line.startsWith...
      ]#

proc handleExecute(shell: var Shell, msg: WireMessage) =
  ## Handle the ``execute_request`` message
  #debug "HANDLEEXECUTE\n", msg
  inc shell.count

  #TODO: in the future outputs will become a seq[string] so that
  # streams can be sent line by line
  let 
    code = msg.content["code"].str # The code to be executed
    # this "fixes" cases in which the frontend doesn't expose the cellid, by 
    # requiring users to add a #>cellId:<something> to their cell code.
    # If they don't, we use the message id of the execute_req message.
    # Problem: this last way destroys the ability to track a cell since there's no
    # way to map the cell being re run to its old code, causing compilation errors
    # very fast
    # TODO: follow up issues for vscode-python, nteract to expose this in the cell
    cellId =  if msg.metadata.hasKey("cellId"): msg.metadata["cellId"].str
              elif code.startsWith("#>cellId"): code.splitLines()[0]
              else: msg.header.msg_id
  
  shell.executingCellId = cellId

  shell.pub.lastmsg = msg # update execute msg

  # TODO: move the logic that deals with magics and flags somewhere else
  if code.contains("#>flags"):  
    let 
      flagstart = code.find("#>flags")+"#>flags".len+1
      nwline = code.find("\u000A", flagstart)
      flagend = if nwline != -1: nwline else: code.len
    flags = code[flagstart..flagend].split()

    debug "with custom flags:", flags.flatten

  if code.contains("#>clear all") and dirExists(jnTempDir):
    debug "Cleaning up..."
    flags = @defaultFlags
    removeDir(jnTempDir)
    createDir(jnTempDir)
    shell.code.clear
    shell.code["initialCell"] = initialCodecell
    shell.executingCellId = ""
    let tmp = shell.updateCodeServer()
    debug tmp
    # TODO: resets flags properly
    when defined useHcr:
      shell.codeserver = shell.startCodeServer

  # Send via iopub the block about to be executed
  var content = %* {
      "execution_count": shell.count,
      "code": code,
  }
  shell.pub.sendMsg(execute_input, content, msg)

  # Compile and send compilation messages to jupyter's stdout
  shell.code[cellId] = code
  var compilationResult = shell.updateCodeServer()

  # debug "file before:"
  # debug readFile(jnTempDir / "codecells.nim")
  # debug "file end"

  # debug "server has data: ", shell.codeserver.hasData
  
  var status, streamName: string
  
  if compilationResult.exitcode != 0: 
    # return early if the code didn't compile
    status = "error"
    streamName = "stderr"
    
    # execution not ok, remove last cell
    
    #debug "Compilation error, discarding last code cell"
    var discardedCell = ""
    discard shell.code.pop(cellId, discardedCell) # TODO:care about the bool result
    debug "Discarded:" & discardedCell
    #debug "file after:"
    #debug readFile(jnTempDir / "codecells.nim")
    #debug "file end"

    content = %*{
      "name": streamName, 
      "text": compilationResult.output
    }
    shell.pub.sendMsg(stream, content, msg)

    content = %* {
      "status": status,
      "ename": "Compile error", # Exception name, as a string
      "evalue": "Error", # Exception value, as a string
      "traceback": nil, # traceback frames as strings, TODO:
    }
    shell.pub.sendMsg(WireType.error, content, msg)
    # Tell the frontend execution failed from shell
    content = %* {
      "status": status,
      "execution_count": shell.count,
    }
    shell.sendMsg(execute_reply, content, msg)
    
    return

  status = "ok"
  streamName = "stdout"
  
  content = %*{"name": streamName, "text": compilationResult.output}

  # Send compiler messages
  shell.pub.sendMsg(WireType.stream, content, msg)

  # Since the compilation was fine, run code and send results with iopub
  var exec_out: string
  # run the new code
  when defined useHcr:
    shell.codeserver.inputStream.writeLine("#runNimCodeServer")
    shell.codeserver.inputStream.flush

    #debug "trying to read all...", shell.codeserver.hasData
    
    var donewriting = false
    while not doneWriting:
      let tmp = shell.codeserver.outputStream.readLine
      if tmp.rfind("#serverReplied") != -1: 
        donewriting = true
        break # we dont want the last message anyway
      exec_out &= tmp & "\n"
  else:
    exec_out = execProcess(jnTempDir / outCodeServerName)
    #debug exec_out
    # we are only interested in new output
    let execoutsplit = exec_out.rsplit("#>newcodeout")
    #debug "Split length ", len(execoutsplit)
    if execoutsplit.len > 0: exec_out = execoutsplit[^1]
  
  #debug "done reading, read: ", exec_out
  
  # TODO: don't assume no errors are possible at runtime, 
  #       check for errors there too

  if exec_out.contains("#<jndd>"): 
    # FIXME: document this!
    debug "Handling display data"
    # there's at least a plot TODO: multiple plots (rfind is dangerous in that case)
    # plotdata is base64 encoded! and delimited by jpns and 0000x0000 that is WxH
    # TODO: we probably want to remove this part from the output?
    # also needs a filetype parameter
    # Maybe just put code to open a socket and send a display_data message in a utils lib
    # and let the user/plotlib deal with this? Much cleaner?
    let
      ddstart = exec_out.rfind("#<jndd>#")
      ddend = exec_out.rfind("#<outjndd>#")
    let dddata = exec_out[ddstart+len("#<jndd>#")..<ddend]
    content = parseJson(dddata)
    shell.pub.sendMsg(display_data, content, msg)
    exec_out = exec_out.replace(dddata, "") # clear out the base64 img from the output
  
  content = %*{
      "execution_count": shell.count,
      "data": {"text/plain": exec_out}, # TODO: detect and handle other mimetypes
      "metadata": %*{}
  }
  shell.pub.sendMsg(execute_result, content, msg)

  # Tell the frontend execution was ok, or not from shell
  content = %* {
    "status": status,
    "execution_count": shell.count,
    "payload": {},
    "user_expressions": {},
  }
  shell.sendMsg(execute_reply, content, msg)

proc parseNimsuggest(nims: string): tuple[found: bool, data: JsonNode] =
  # nimsuggest output is \t separated
  # http://nim-lang.org/docs/nimsuggest.html#parsing-nimsuggest-output
  discard

proc handleIntrospection(shell: Shell, msg: WireMessage) =
  #[ reply
    content = {
    # 'ok' if the request succeeded or 'error', with error information as in all other replies.
    'status' : 'ok',
    # found should be true if an object was found, false otherwise
    'found' : bool,
    # data can be empty if nothing is found
    'data' : dict,
    'metadata' : dict,
    }
  ]#
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
  shell.sendMsg(inspect_reply, content, msg)

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
  shell.sendMsg(complete_reply, content, msg)

proc handleHistory(shell: Shell, msg: WireMessage) =
  debug "Unhandled: history"
  var content = %* {
    # A list of 3 tuples, either:
      # (session, line_number, input) or
      # (session, line_number, (input, output)),
      # depending on whether output was False or True, respectively.
    "history": [],
  }
  shell.sendMsg(history_reply, content, msg)


proc handleCommInfo(s: Shell, msg: WireMessage) =
  debug "Unhandled: CommInfoReq"
  if msg.content.hasKey("target_name"):
    debug "CommInfo about ", msg.content["target_name"].getStr
    # A dictionary of the comms, indexed by uuids (comm_id).
    #[content = {  'comms': { comm_id: { 'target_name': str,  },    }, }]#
    var content = %* { "comms":  {} } # TODO: don't care
    s.sendMsg(WireType.comm_info_reply, content, msg)
  else:
    var content = %* { "comms":  {} } # TODO: don't care
    s.sendMsg(WireType.comm_info_reply, content, msg)

proc handle(s: var Shell, m: WireMessage) =
  debug "shell: handle ", m.msg_type
  case m.msg_type
  of kernelInfoRequest:
    debug "Sending Kernel info"
    handleKernelInfo(s, m)
  of executeRequest:
    handleExecute(s, m)
  of shutdownRequest:
    debug "kernel wants to shutdown"
    quit()
  of inspectRequest: handleIntrospection(s, m)
  of completeRequest: handleCompletion(s, m)
  of historyRequest: handleHistory(s, m)
  of commInfoRequest: handleCommInfo(s, m)
  else:
    debug "unhandled message: ", m.msg_type

proc receive*(shell: var Shell) =
  ## Receive a message on the shell socket, decode it and handle operations
  let recvdmsg: WireMessage = shell.receiveMsg()
  debug "shell: ", $recvdmsg.msg_type
  #debug recvdmsg.content
  #debug "end shell"
  shell.pub.sendState("busy", recvdmsg)
  shell.handle(recvdmsg)
  shell.pub.sendState("idle", recvdmsg)

proc close*(sl: var Shell) =
  sl.socket.close()
  when defined useHcr:
    sl.codeserver.terminate()


## Control socket
proc createControl*(ip: string, port: BiggestInt): Control =
  ## Create the control socket
  result.socket = zmq.listen("tcp://" & ip & ":" & $port, zmq.ROUTER)


proc handle(c: Control, m: WireMessage) =
  if m.msg_type == shutdown_request:
    #var content : JsonNode
    debug "shutdown requested"
    #content = %* { "restart": false }
    c.sendMsg(shutdown_reply, m.content, m)
    quit()
  else:
    debug "Control: unhandled message ", m.msg_type

proc receive*(cont: Control) =
  ## Receive a message on the control socket and handle operations
  let recvdmsg: WireMessage = cont.receiveMsg()
  debug "received: ", $recvdmsg.msg_type
  cont.handle(recvdmsg)
