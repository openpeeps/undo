# undo - A persistent undo/redo history manager
# Supports snapshots, diffs, and JSON document states
# Backed by boogie LogStore for append-only durability

import std/[options, json, strutils]
import pkg/openparser/fbe
import pkg/boogie/stores/logstore

const
  HistoryVersion = 1'u8

type
  EntryKind* = enum
    ekSnapshot
    ekDiff
    ekJson

  HistoryEntry* = object
    case kind*: EntryKind
    of ekSnapshot:
      content*: string
    of ekDiff:
      offset*: int
      deletedLen*: int
      inserted*: string
    of ekJson:
      data*: JsonNode

  HistoryContent* = object
    case kind*: EntryKind
    of ekSnapshot:
      text*: string
    of ekDiff:
      diffOffset*: int
      diffDeleted*: int
      diffInserted*: string
    of ekJson:
      jsonData*: JsonNode

  HistoryManager* = ref object
    log: LogStore
    historyId: string
    currentVersion: int
    pendingGroup: seq[HistoryEntry]
    inGroup: bool

  HistoryError* = object of CatchableError

# --- serialization (FBE manual encoding) ---

proc encodeEntry(entry: HistoryEntry): string =
  var buf = initBuffer()
  writeByte(buf, HistoryVersion)
  case entry.kind
  of ekSnapshot:
    writeByte(buf, 0'u8)
    writeString(buf, entry.content)
  of ekDiff:
    writeByte(buf, 1'u8)
    writeInt32LE(buf, entry.offset.int32)
    writeInt32LE(buf, entry.deletedLen.int32)
    writeString(buf, entry.inserted)
  of ekJson:
    writeByte(buf, 2'u8)
    writeString(buf, $entry.data)
  result = cast[string](buf.data)

proc decodeEntry(data: string): HistoryEntry =
  var buf = initBuffer()
  buf.data = cast[seq[uint8]](@data)
  let version = readByte(buf)
  if version != HistoryVersion:
    raise newException(HistoryError, "unsupported entry version: " & $version)
  let kind = readByte(buf)
  case kind
  of 0:
    result = HistoryEntry(kind: ekSnapshot, content: readString(buf))
  of 1:
    result = HistoryEntry(
      kind: ekDiff,
      offset: readInt32LE(buf).int,
      deletedLen: readInt32LE(buf).int,
      inserted: readString(buf)
    )
  of 2:
    let jsonStr = readString(buf)
    result = HistoryEntry(kind: ekJson, data: parseJson(jsonStr))
  else:
    raise newException(HistoryError, "unknown entry kind: " & $kind)

# --- metadata persistence ---

proc metaStream(h: HistoryManager): string =
  h.historyId & ":_meta"

proc saveMeta(h: HistoryManager) =
  let payload = $h.currentVersion
  h.log.append(h.metaStream(), payload, sync = true)

proc loadMeta(h: HistoryManager) =
  let metaLen = h.log.len(h.metaStream())
  if metaLen > 0:
    let last = h.log.last(h.metaStream(), 1)
    if last.len > 0:
      h.currentVersion = parseInt(last[0].payload)
    else:
      h.currentVersion = 0
  else:
    h.currentVersion = 0
  # Clamp to actual data stream length
  let dataLen = h.log.len(h.historyId)
  if h.currentVersion > dataLen:
    h.currentVersion = dataLen

# --- construction ---

proc newHistoryManager*(path: string, historyId: string,
    cacheCapacity: int = 1024): HistoryManager =
  if historyId.len == 0:
    raise newException(HistoryError, "historyId cannot be empty")
  result = HistoryManager(
    log: openLogStore(path, historyId, cacheCapacity = cacheCapacity),
    historyId: historyId,
    currentVersion: 0,
    pendingGroup: @[],
    inGroup: false
  )
  result.loadMeta()

proc newInMemoryHistoryManager*(historyId: string): HistoryManager =
  if historyId.len == 0:
    raise newException(HistoryError, "historyId cannot be empty")
  result = HistoryManager(
    log: newInMemoryLogStore(),
    historyId: historyId,
    currentVersion: 0,
    pendingGroup: @[],
    inGroup: false
  )
  result.loadMeta()

# --- push ---

proc pushEntry(h: HistoryManager, entry: HistoryEntry) =
  if h.inGroup:
    h.pendingGroup.add(entry)
    return
  h.log.append(h.historyId, encodeEntry(entry), sync = false)
  h.currentVersion = h.log.len(h.historyId)
  h.saveMeta()

proc pushSnapshot*(h: HistoryManager, content: string) =
  h.pushEntry(HistoryEntry(kind: ekSnapshot, content: content))

proc pushDiff*(h: HistoryManager, offset, deletedLen: int, inserted: string) =
  h.pushEntry(HistoryEntry(kind: ekDiff, offset: offset,
    deletedLen: deletedLen, inserted: inserted))

proc pushJson*(h: HistoryManager, data: JsonNode) =
  h.pushEntry(HistoryEntry(kind: ekJson, data: data))

# --- grouping ---

proc beginGroup*(h: HistoryManager) =
  if h.inGroup:
    raise newException(HistoryError, "already in a group")
  h.inGroup = true
  h.pendingGroup = @[]

proc endGroup*(h: HistoryManager) =
  if not h.inGroup:
    raise newException(HistoryError, "not in a group")
  h.inGroup = false
  for entry in h.pendingGroup:
    h.log.append(h.historyId, encodeEntry(entry), sync = false)
  h.currentVersion = h.log.len(h.historyId)
  h.saveMeta()
  h.pendingGroup = @[]

# --- cursor ---

proc canUndo*(h: HistoryManager): bool =
  h.currentVersion > 0

proc canRedo*(h: HistoryManager): bool =
  h.currentVersion < h.log.len(h.historyId)

proc contentFromEntry(entry: LogRecord): Option[HistoryContent] =
  let e = decodeEntry(entry.payload)
  case e.kind
  of ekSnapshot:
    some(HistoryContent(kind: ekSnapshot, text: e.content))
  of ekDiff:
    some(HistoryContent(kind: ekDiff, diffOffset: e.offset,
      diffDeleted: e.deletedLen, diffInserted: e.inserted))
  of ekJson:
    some(HistoryContent(kind: ekJson, jsonData: e.data))

proc undo*(h: HistoryManager): Option[HistoryContent] =
  if not h.canUndo:
    return none(HistoryContent)
  dec h.currentVersion
  h.saveMeta()
  let entry = h.log.get(h.historyId, uint64(h.currentVersion))
  if entry.isNone:
    return none(HistoryContent)
  contentFromEntry(entry.get())

proc redo*(h: HistoryManager): Option[HistoryContent] =
  if not h.canRedo:
    return none(HistoryContent)
  inc h.currentVersion
  h.saveMeta()
  let entry = h.log.get(h.historyId, uint64(h.currentVersion))
  if entry.isNone:
    return none(HistoryContent)
  contentFromEntry(entry.get())

proc undoText*(h: HistoryManager): Option[string] =
  let content = h.undo()
  if content.isSome and content.get().kind == ekSnapshot:
    some(content.get().text)
  else:
    none(string)

proc undoJson*(h: HistoryManager): Option[JsonNode] =
  let content = h.undo()
  if content.isSome and content.get().kind == ekJson:
    some(content.get().jsonData)
  else:
    none(JsonNode)

# --- lifecycle ---

proc close*(h: HistoryManager) =
  h.log.close()
