import json, utils, md5

type WireType* = enum
  Unknown = 0
  Kernel_Info = 1
  Execute = 2

  Introspection = 3
  Completion = 4
  History = 5
  Complete = 6
  Comm_info = 7

  Status = 9
  Shutdown = 10

  Comm_Open = 21 # not defined in spec?

type ConnectionMessage* = object
  ## The connection message the notebook sends when starting
  ip*: string
  transport*: string
  signature_scheme*: string
  key*: string
  hb_port*, iopub_port*, shell_port*, stdin_port*, control_port*: int
  kernel_name*: string

proc parseConnMsg*(connfile: string): ConnectionMessage =
  let parsedconn = parseFile(connfile)
  result.ip = parsedconn["ip"].str
  result.signature_scheme = parsedconn["signature_scheme"].str
  result.key = parsedconn["key"].str
  result.hb_port = parsedconn["hb_port"].num.int
  result.iopub_port = parsedconn["iopub_port"].num.int
  result.shell_port = parsedconn["shell_port"].num.int
  result.stdin_port = parsedconn["stdin_port"].num.int
  result.control_port = parsedconn["control_port"].num.int
  result.transport = parsedconn["transport"].str
  if parsedconn.hasKey("kernel_name"):
    result.kernel_name = parsedconn["kernel_name"].str
  else: result.kernel_name = "N/A?"
  # TODO: handle transport method?

proc `$`*(cm: ConnectionMessage): string =
  result = "ip: " & cm.ip &
            "\nsignature_scheme: " & cm.signature_scheme &
            "\nkey: " & cm.key &
            "\nhb_port: " & $cm.hb_port &
            "\niopub_port: " & $cm.iopub_port &
            "\nshell_port: " & $cm.shell_port &
            "\nstdin_port: " & $cm.stdin_port &
            "\ncontrol_port: " & $cm.control_port &
            "\ntransport: " & $cm.transport &
            "\nkernel_name: " & cm.kernel_name

type WireMessage* = object
  msg_type*: WireType # Convenience, this is not part of the spec
  ## Describes a raw message as passed by Jupyter/Ipython
  ## Follows https://jupyter-client.readthedocs.io/en/stable/messaging.html#the-wire-protocol
  ident*: string      # uuid
  signature*: string  # hmac signature
  header*: JsonNode
  parent_header*: JsonNode
  metadata*: JsonNode
  content*: JsonNode
  extra*: string      # Extra raw data

proc decode*(raw: openarray[string]): WireMessage =
  ## decoedes a wire message as a seq of string blobs into a WireMessage object
  ## FIXME: only handles the first 7 parts, the extra raw data is discarded
  result.ident = raw[0]
  #debug "IN"
  #debug raw
  if len(raw)>7:
    debug "BUFFERS", raw[8]


  doAssert(raw[1] == "<IDS|MSG>", "Malformed message follows:\n" & $raw & "\nMalformed message ends\n")

  result.signature = raw[2]
  try:
    result.header = parseJson(raw[3]).to(WireHeader)
  except KeyError as e:
    var jsonheader = parseJson(raw[3]) 
    debug e.msg, "json: ", parseJson(raw[3])
    #if spec 5.2 date isn't here???
    jsonheader["date"] = % ""
    result.header = jsonheader.to(WireHeader)
  try:
    result.parent_header = some(parseJson(raw[4]).to(WireHeader))
  except KeyError as e:
    var jsonheader = parseJson(raw[4])
    debug e.msg, "parent json: ", jsonheader
    result.parent_header = none(WireHeader)
  result.metadata = parseJson(raw[5])
  result.content = parseJson(raw[6])

  doAssert(result.header.hasKey("msg_type"), "Message had no msg_type")

  case result.header["msg_type"].str:
  of "kernel_info_request": result.msg_type = WireType.Kernel_Info
  of "shutdown_request": result.msg_type = WireType.Shutdown
  of "execute_request": result.msg_type = WireType.Execute
  of "inspect_request": result.msg_type = WireType.Introspection
  of "complete_request": result.msg_type = WireType.Completion
  of "history_request": result.msg_type = WireType.History
  of "is_complete_request": result.msg_type = WireType.Complete
  of "comm_info_request": result.msg_type = WireType.Comm_info
  of "comm_open":
    result.msg_type = WireType.Comm_Open
    debug "unused msg: comm_open"
  else:
    result.msg_type = WireType.Unknown
    debug "Unknown WireMsg: ", result.header,
        " follows:" # Dump unknown messages
    debug result.content
    debug "Unknown WireMsg End"



proc encode*(reply_type: string, content: JsonNode, key: string,
    parent: varargs[WireMessage]): seq[string] =
  ## Encode a message following wire spec
  let iopubTopics = [ #TODO: move to an enum?
    "execute_result",
    "stream",
    "display_data",
    "update_display_data",
    "execute_input",
    "error",
    "status",
    "clear_output",
    "debug_event"
  ]
  let header: JsonNode = %* {
    "msg_id": genUUID(), # typically UUID, must be unique per message
    "username": "kernel",
    "session": key.getmd5(), # using md5 of key as we passed it here already, SECURITY RISK?
    "date": getISOstr(), # ISO 8601 timestamp for when the message is created
    "msg_type": reply_type, # TODO: use an enum?
    "version": "5.3",    # the message protocol version
  }

  var
    metadata: JSonNode = %* {}
    maybeParent: WireMessage
  #debug "parent length:", parent.len
  if parent.len == 0:
    # TODO: document this
    #debug "Parent had 0 length for ", reply_type
    maybeParent.ident = "kernel"
    maybeParent.header = %*{}
  else:
    maybeParent = parent[0]

  if  reply_type in iopubTopics: 
    # FIXME: IOPUB has special treatment RE: idents see
    # https://jupyter-client.readthedocs.io/en/stable/messaging.html#the-wire-protocol
    result = @[reply_type]
  else:
    result = @[maybeParent.ident] # Add ident

  result &= "<IDS|MSG>" # add separator

  let partToSign = $header & $maybeParent.header & $metadata & $content
  result &= sign(partToSign, key)
  result &= $header
  result &= $maybeParent.header
  result &= $metadata
  result &= $content
  #result &= "{}" #empty buffers

  #debug "OUT"
  #debug result

type 
  CommKind {.pure.} = enum
    Open, Close, Msg
  Comm* = object
    comm_id*: string # 'u-u-i-d',
    data* : JsonNode # {}
    case kind: CommKind
    of CommKind.Open:
      target_name*: string # 'my_comm', only for comm_open
    else: discard


proc openComm*(target: string, data: JsonNode = %* {} ): Comm =
  result = Comm(kind: CommKind.Open, comm_id: genUUID(), target_name: target, data: data)

proc comm*(c: Comm, data: JsonNode = %* {}): Comm =
  result = Comm(kind: CommKind.Msg, comm_id: c.comm_id, data: data)

proc closeComm*(c: Comm, data: JsonNode = %* {}): Comm =
  result = Comm(kind: CommKind.Close, comm_id: c.comm_id, data: data)
