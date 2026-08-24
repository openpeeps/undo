# undo - A persistent undo/redo history manager
# Supports snapshots, text diffs, JSON states, and JSON Patch deltas
# Backed by boogie LogStore for append-only durability

import std/[options, json, strutils, os, times]
import pkg/openparser/fbe
import pkg/boogie/stores/logstore

const
  HistoryVersion = 2'u8

type
  EntryKind* = enum
    ekSnapshot
    ekDiff
    ekJson
    ekJsonPatch

  JsonPatchOpKind* = enum
    jpoAdd
    jpoRemove
    jpoReplace

  JsonOp* = object
    ## One RFC 6902-style operation addressed by an RFC 6901 JSON Pointer
    op*: JsonPatchOpKind
    path*: string
    value*: JsonNode
      ## Target value; unused for `jpoRemove`

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
    of ekJsonPatch:
      fwdOps*: seq[JsonOp]
        ## Operations moving a document newer-ward (redo direction)
      bwdOps*: seq[JsonOp]
        ## Precomputed inverse operations (undo direction)

  HistoryContent* = object
    tsUnix*: int64
      ## Unix timestamp (seconds) stamped when the entry was recorded
    case kind*: EntryKind
    of ekSnapshot:
      text*: string
    of ekDiff:
      diffOffset*: int
      diffDeleted*: int
      diffInserted*: string
    of ekJson:
      jsonData*: JsonNode
    of ekJsonPatch:
      patchForward*: seq[JsonOp]
      patchBackward*: seq[JsonOp]

  NowFn* = proc(): int64 {.gcsafe.}
    ## Millisecond clock used for idle-window auto-grouping; injectable
    ## for deterministic tests

  HistoryManager* = ref object
    log: LogStore
    historyId: string
    basePath: string
      ## Directory holding this history's WAL file; empty for in-memory stores
    cacheCapacity: int
    gen: int
      ## Active generation. Each push after an undo rotates to a fresh
      ## generation stream holding only live entries, which keeps logical
      ## positions equal to physical sequence numbers and makes orphaned
      ## futures unreachable.
    currentVersion: int
      ## Cursor position within the active generation (0 = before first entry)
    maxVersions: int
      ## Soft cap on live history depth; 0 disables capping. Pruning is
      ## amortized: rotation happens once the stream exceeds twice the cap,
      ## keeping the most recent `maxVersions` entries.
    tags: seq[uint32]
      ## Step tag per live position (`tags[i]` belongs to position `i + 1`).
      ## Consecutive positions sharing a tag form one undoable step; undo
      ## and redo land on tag boundaries rather than individual entries.
    nextTag: uint32
      ## Highest tag seen; incremented whenever a new step begins
    pendingGroup: seq[HistoryEntry]
      ## Queued entries for either an open manual group or an active
      ## auto-grouping window (never both at once)
    inGroup: bool
    autoGroupMs: int
      ## Idle-window size for automatic coalescing; 0 disables
    autoGroupMax: int
      ## Hard cap on entries queued per auto-grouped step
    lastPushMs: int64
      ## Clock reading of the last direct push; -1 when the next push should
      ## start a fresh step regardless of the window
    nowMs: NowFn

  HistoryError* = object of CatchableError

proc defaultNowMs(): int64 {.gcsafe.} =
  (epochTime() * 1000.0).int64

# --- serialization (FBE manual encoding) ---
#
# Wire format v2: [ver u8][kind u8][stepTag u32le][kind-specific payload]
# v1 payloads ([ver][kind][payload], no tag) still decode; their records
# behave as single-entry steps.

proc opsToJson(ops: seq[JsonOp]): JsonNode =
  result = newJArray()
  for o in ops:
    var n = %*{"op": $o.op, "path": o.path}
    if o.op != jpoRemove:
      n["value"] = o.value
    result.add(n)

proc jsonToOps(n: JsonNode): seq[JsonOp] =
  for item in n.items:
    var o = JsonOp(
      op: parseEnum[JsonPatchOpKind](item["op"].getStr()),
      path: item["path"].getStr()
    )
    if o.op != jpoRemove and item.hasKey("value"):
      o.value = item["value"]
    result.add(o)

proc encodeEntry(entry: HistoryEntry, tag: uint32): string =
  var buf = initBuffer()
  writeByte(buf, HistoryVersion)
  case entry.kind
  of ekSnapshot:
    writeByte(buf, 0'u8)
    writeUint32LE(buf, tag)
    writeString(buf, entry.content)
  of ekDiff:
    writeByte(buf, 1'u8)
    writeUint32LE(buf, tag)
    writeInt32LE(buf, entry.offset.int32)
    writeInt32LE(buf, entry.deletedLen.int32)
    writeString(buf, entry.inserted)
  of ekJson:
    writeByte(buf, 2'u8)
    writeUint32LE(buf, tag)
    writeString(buf, $entry.data)
  of ekJsonPatch:
    writeByte(buf, 3'u8)
    writeUint32LE(buf, tag)
    writeString(buf, $opsToJson(entry.fwdOps))
    writeString(buf, $opsToJson(entry.bwdOps))
  result = cast[string](buf.data)

proc decodeRecord(data: string): (HistoryEntry, uint32) =
  var buf = initBuffer()
  buf.data = cast[seq[uint8]](@data)
  let version = readByte(buf)
  let kind = readByte(buf)
  var tag = 0'u32
  if version >= 2:
    tag = readUint32LE(buf)
  elif version != 1:
    raise newException(HistoryError, "unsupported entry version: " & $version)
  case kind
  of 0:
    result = (HistoryEntry(kind: ekSnapshot, content: readString(buf)), tag)
  of 1:
    result = (HistoryEntry(
      kind: ekDiff,
      offset: readInt32LE(buf).int,
      deletedLen: readInt32LE(buf).int,
      inserted: readString(buf)
    ), tag)
  of 2:
    let jsonStr = readString(buf)
    result = (HistoryEntry(kind: ekJson, data: parseJson(jsonStr)), tag)
  of 3:
    let fwdStr = readString(buf)
    let bwdStr = readString(buf)
    result = (HistoryEntry(
      kind: ekJsonPatch,
      fwdOps: jsonToOps(parseJson(fwdStr)),
      bwdOps: jsonToOps(parseJson(bwdStr))
    ), tag)
  else:
    raise newException(HistoryError, "unknown entry kind: " & $kind)

# --- JSON Pointer (RFC 6901) and patch application ---

proc pointerTokens(path: string): seq[string] =
  ## Splits a JSON Pointer into unescaped reference tokens. The empty path
  ## addresses the whole document.
  if path.len == 0:
    return
  var first = true
  for raw in path.split('/'):
    if first and raw.len == 0:
      first = false
      continue   # consume the leading '/'
    first = false
    result.add(raw.replace("~1", "/").replace("~0", "~"))

proc escapeKey(k: string): string =
  k.replace("~", "~0").replace("/", "~1")

proc navigateToParent(root: JsonNode, tokens: seq[string]): JsonNode =
  ## Walks to the container holding the final token. Raises when an
  ## intermediate segment is missing or not a container.
  result = root
  for i in 0 ..< tokens.len - 1:
    let tok = tokens[i]
    if result.kind == JObject:
      if not result.hasKey(tok):
        raise newException(HistoryError,
          "patch path not found: " & tokens[0 .. i].join("/"))
      result = result[tok]
    elif result.kind == JArray:
      let idx = try: parseInt(tok)
                except ValueError:
                  raise newException(HistoryError, "bad array index: " & tok)
      if idx < 0 or idx >= result.len:
        raise newException(HistoryError, "array index out of range: " & tok)
      result = result[idx]
    else:
      raise newException(HistoryError,
        "patch path crosses a scalar at: " & tokens[0 .. i].join("/"))

proc applySingleOp(root: var JsonNode, o: JsonOp) =
  let tokens = pointerTokens(o.path)
  if tokens.len == 0:
    # whole-document operation
    case o.op
    of jpoReplace, jpoAdd:
      root = o.value.copy()
    of jpoRemove:
      raise newException(HistoryError, "cannot remove the whole document")
    return

  let lastTok = tokens[^1]
  var parent = navigateToParent(root, tokens)

  case parent.kind
  of JObject:
    case o.op
    of jpoAdd, jpoReplace:
      if o.op == jpoReplace and not parent.hasKey(lastTok):
        raise newException(HistoryError, "replace target missing: " & o.path)
      parent[lastTok] = o.value.copy()
    of jpoRemove:
      if not parent.hasKey(lastTok):
        raise newException(HistoryError, "remove target missing: " & o.path)
      delete(parent, lastTok)
  of JArray:
    case o.op
    of jpoAdd:
      if lastTok == "-":
        parent.add(o.value.copy())
      else:
        let idx = try: parseInt(lastTok)
                  except ValueError:
                    raise newException(HistoryError, "bad array index: " & lastTok)
        if idx < 0 or idx > parent.len:
          raise newException(HistoryError, "array insert out of range: " & o.path)
        parent.elems.insert(o.value.copy(), idx)
    of jpoReplace:
      let idx = try: parseInt(lastTok)
                except ValueError:
                  raise newException(HistoryError, "bad array index: " & lastTok)
      if idx < 0 or idx >= parent.len:
        raise newException(HistoryError, "array index out of range: " & o.path)
      parent.elems[idx] = o.value.copy()
    of jpoRemove:
      let idx = try: parseInt(lastTok)
                except ValueError:
                  raise newException(HistoryError, "bad array index: " & lastTok)
      if idx < 0 or idx >= parent.len:
        raise newException(HistoryError, "array index out of range: " & o.path)
      parent.elems.delete(idx)
  else:
    raise newException(HistoryError, "patch target parent is a scalar: " & o.path)

proc applyOps*(doc: JsonNode, ops: seq[JsonOp]): JsonNode =
  ## Returns a copy of `doc` with RFC 6902-style operations applied in order.
  ## Arrays are addressed by index (or `-` to append). Raises `HistoryError`
  ## on missing targets or malformed paths.
  result = doc.copy()
  for o in ops:
    applySingleOp(result, o)

proc diffWalk(prev, next: JsonNode, basePath: string,
    fwd, bwd: var seq[JsonOp]) =
  if prev.kind == JObject and next.kind == JObject:
    # keys removed
    for k in prev.keys:
      if not next.hasKey(k):
        let p = basePath & "/" & escapeKey(k)
        fwd.add(JsonOp(op: jpoRemove, path: p))
        bwd.insert(JsonOp(op: jpoAdd, path: p, value: prev[k]), 0)
    # keys added
    for k in next.keys:
      if not prev.hasKey(k):
        let p = basePath & "/" & escapeKey(k)
        fwd.add(JsonOp(op: jpoAdd, path: p, value: next[k]))
        bwd.insert(JsonOp(op: jpoRemove, path: p), 0)
    # recurse into shared keys
    for k in prev.keys:
      if next.hasKey(k):
        diffWalk(prev[k], next[k], basePath & "/" & escapeKey(k), fwd, bwd)
  elif $prev != $next:
    # differing shapes or values collapse to one atomic replace; arrays are
    # intentionally replaced wholesale in this revision
    fwd.add(JsonOp(op: jpoReplace, path: basePath, value: next))
    bwd.insert(JsonOp(op: jpoReplace, path: basePath, value: prev), 0)

proc jsonDiff*(prevState, newState: JsonNode): tuple[fwd, bwd: seq[JsonOp]] =
  ## Computes forward and inverse operation sets transforming `prevState`
  ## into `newState`. Objects are walked recursively; anything else
  ## (scalars and arrays alike) diffs atomically as one replace.
  diffWalk(prevState, newState, "", result.fwd, result.bwd)

# --- stream naming ---

proc genStream(h: HistoryManager): string =
  h.historyId & ":g" & $h.gen

proc metaStream(h: HistoryManager): string =
  h.historyId & ":_meta"

# --- step-tag index ---

proc rebuildTags(h: HistoryManager) =
  ## Scans the active generation and rebuilds the per-position tag index,
  ## also advancing `nextTag` past anything recovered.
  h.tags = @[]
  var mx = 0'u32
  for rec in h.log.forward(h.genStream()):
    let (_, tg) = decodeRecord(rec.payload)
    h.tags.add(tg)
    if tg > mx:
      mx = tg
  h.nextTag = mx

proc newTag(h: HistoryManager): uint32 =
  inc h.nextTag
  h.nextTag

proc tagAt(h: HistoryManager, pos: int): uint32 =
  h.tags[pos - 1]

# --- metadata persistence ---

proc saveMeta(h: HistoryManager) =
  let payload = $(%*{"gen": h.gen, "cur": h.currentVersion})
  h.log.append(h.metaStream(), payload, sync = true)

proc loadMeta(h: HistoryManager) =
  h.gen = 0
  let metaLen = h.log.len(h.metaStream())
  if metaLen > 0:
    let last = h.log.last(h.metaStream(), 1)
    if last.len > 0:
      try:
        let meta = parseJson(last[0].payload)
        h.gen = meta["gen"].getInt()
        h.currentVersion = meta["cur"].getInt()
      except CatchableError:
        # corrupt metadata record; fall back to treating every recovered
        # entry as applied
        h.rebuildTags()
        h.currentVersion = h.log.len(h.genStream())
        return
  else:
    # no metadata yet: a fresh store has nothing applied; a store that lost
    # its metadata still owns its data, so treat all entries as current
    h.currentVersion = h.log.len(h.genStream())
  # clamp against what actually survived recovery
  h.rebuildTags()
  let dataLen = h.log.len(h.genStream())
  if h.currentVersion > dataLen:
    h.currentVersion = dataLen

# --- construction ---

proc newHistoryManager*(path: string, historyId: string,
    maxVersions: int = 0, autoGroupMs: int = 0, autoGroupMax: int = 64,
    cacheCapacity: int = 1024): HistoryManager =
  ## Opens or creates a disk-backed history under directory `path`.
  ##
  ## `maxVersions` softly caps how many entries stay reachable. Once the
  ## active stream grows past twice the cap, it is rotated to keep only the
  ## most recent `maxVersions` entries (amortized O(1) per push). Pass 0 to
  ## keep unbounded history.
  ##
  ## With `autoGroupMs > 0`, pushes arriving within that idle window are
  ## coalesced into a single undoable step (see `setClock` for test hooks).
  if historyId.len == 0:
    raise newException(HistoryError, "historyId cannot be empty")
  result = HistoryManager(
    log: openLogStore(path, historyId, cacheCapacity = cacheCapacity),
    historyId: historyId,
    basePath: path,
    cacheCapacity: cacheCapacity,
    gen: 0,
    currentVersion: 0,
    maxVersions: maxVersions,
    pendingGroup: @[],
    inGroup: false,
    autoGroupMs: autoGroupMs,
    autoGroupMax: autoGroupMax,
    lastPushMs: -1'i64,
    nowMs: defaultNowMs
  )
  result.loadMeta()

proc newInMemoryHistoryManager*(historyId: string, maxVersions: int = 0,
    autoGroupMs: int = 0, autoGroupMax: int = 64): HistoryManager =
  ## Creates an ephemeral in-memory history. Nothing touches disk.
  if historyId.len == 0:
    raise newException(HistoryError, "historyId cannot be empty")
  result = HistoryManager(
    log: newInMemoryLogStore(),
    historyId: historyId,
    basePath: "",
    cacheCapacity: 0,
    gen: 0,
    currentVersion: 0,
    maxVersions: maxVersions,
    pendingGroup: @[],
    inGroup: false,
    autoGroupMs: autoGroupMs,
    autoGroupMax: autoGroupMax,
    lastPushMs: -1'i64,
    nowMs: defaultNowMs
  )
  result.loadMeta()

proc setClock*(h: HistoryManager, fn: NowFn) =
  ## Replaces the millisecond clock backing auto-grouping decisions.
  ## Intended for deterministic tests.
  h.nowMs = fn

# --- internal append machinery ---

proc rotateGeneration(h: HistoryManager, fromSeq, toSeq: int) =
  ## Starts a new generation holding verbatim copies of entries
  ## `[fromSeq..toSeq]` from the active one. Payloads are copied without
  ## re-encoding and original timestamps are preserved.
  let src = h.genStream()
  h.gen += 1
  if toSeq >= fromSeq:
    for i in fromSeq .. toSeq:
      let rec = h.log.get(src, uint64(i))
      if rec.isSome:
        discard h.log.append(h.genStream(), rec.get().payload,
          tsUnix = rec.get().tsUnix, sync = false)
  h.rebuildTags()

proc appendEntry(h: HistoryManager, e: HistoryEntry, tag: uint32) =
  ## Appends one entry to the active generation, rotating first when the
  ## cursor sits behind the tail (push after undo) or when the soft cap is
  ## exceeded. After any rotation the active generation contains exactly the
  ## live history, so physical seqNums equal logical positions.
  if h.currentVersion < h.log.len(h.genStream()):
    # divergent push: carry the applied prefix only; the undone future
    # becomes unreachable
    h.rotateGeneration(1, h.currentVersion)

  let s = h.genStream()
  discard h.log.append(s, encodeEntry(e, tag), sync = false)
  h.tags.add(tag)
  h.currentVersion = h.log.len(s)

  if h.maxVersions > 0:
    let n = h.currentVersion
    if n > h.maxVersions * 2:
      # amortized pruning: keep the newest `maxVersions` entries
      h.rotateGeneration(n - h.maxVersions + 1, n)
      h.currentVersion = h.maxVersions

# --- auto-grouping ---

proc flushAuto(h: HistoryManager) =
  ## Drains queued auto-grouped entries as one tagged step. No-op while a
  ## manual group owns the queue or nothing is pending.
  if h.inGroup or h.pendingGroup.len == 0:
    return
  let tag = h.newTag()
  for e in h.pendingGroup:
    h.appendEntry(e, tag)
  h.pendingGroup.setLen(0)
  h.lastPushMs = -1
  h.saveMeta()

proc pushEntry(h: HistoryManager, e: HistoryEntry) =
  ## Routes one pushed entry either into the open manual group, into the
  ## active auto-grouping window, or straight to the log as its own step.
  if h.inGroup:
    h.pendingGroup.add(e)
    return
  if h.autoGroupMs > 0:
    let now = h.nowMs()
    if h.pendingGroup.len == 0:
      # open a fresh window; the first keystroke of a burst joins its step
      h.pendingGroup.add(e)
      h.lastPushMs = now
      return
    if h.pendingGroup.len < h.autoGroupMax and
        (now - h.lastPushMs) <= h.autoGroupMs.int64:
      h.pendingGroup.add(e)
      h.lastPushMs = now
      return
    # window expired or filled: commit it, then start a new one
    h.flushAuto()
    h.pendingGroup.add(e)
    h.lastPushMs = h.nowMs()
    return
  h.appendEntry(e, h.newTag())
  h.saveMeta()

# --- push ---

proc pushSnapshot*(h: HistoryManager, content: string) =
  ## Records a full-text snapshot as a new undoable step
  h.pushEntry(HistoryEntry(kind: ekSnapshot, content: content))

proc pushDiff*(h: HistoryManager, offset, deletedLen: int, inserted: string) =
  ## Records a text diff (offset, deleted character count, inserted text)
  h.pushEntry(HistoryEntry(
    kind: ekDiff, offset: offset,
    deletedLen: deletedLen, inserted: inserted))

proc pushJson*(h: HistoryManager, data: JsonNode) =
  ## Records a full JSON document state
  h.pushEntry(HistoryEntry(kind: ekJson, data: data))

proc pushJsonDiff*(h: HistoryManager, prevState, newState: JsonNode) =
  ## Diffs two JSON document states and records the delta as forward +
  ## inverse operation sets, keeping undo self-contained without storing
  ## full snapshots
  let (fwd, bwd) = jsonDiff(prevState, newState)
  h.pushEntry(HistoryEntry(kind: ekJsonPatch, fwdOps: fwd, bwdOps: bwd))

proc pushJsonPatch*(h: HistoryManager, ops, inverse: seq[JsonOp]) =
  ## Records caller-supplied operation sets directly; `inverse` must undo
  ## exactly what `ops` applies
  h.pushEntry(HistoryEntry(kind: ekJsonPatch, fwdOps: ops, bwdOps: inverse))

# --- grouping ---

proc beginGroup*(h: HistoryManager) =
  ## Opens a batching window; pushes inside it accumulate and are applied
  ## together when `endGroup` closes them as one undoable step
  h.flushAuto()
  if h.inGroup:
    raise newException(HistoryError, "already in a group")
  h.inGroup = true
  h.pendingGroup = @[]
  h.lastPushMs = -1

proc endGroup*(h: HistoryManager) =
  ## Closes the batching window and appends everything collected since
  ## `beginGroup` under a single step tag
  if not h.inGroup:
    raise newException(HistoryError, "not in a group")
  h.inGroup = false
  if h.pendingGroup.len > 0:
    let tag = h.newTag()
    for entry in h.pendingGroup:
      h.appendEntry(entry, tag)
    h.pendingGroup.setLen(0)
    h.saveMeta()
  h.lastPushMs = -1

# --- step-boundary cursor arithmetic ---

proc undoTargetPos(h: HistoryManager): int =
  ## Newest position before the cursor whose step differs from the cursor's
  ## own step; 0 lands on the pristine state
  if h.currentVersion <= 0:
    return 0
  let curTag = h.tagAt(h.currentVersion)
  result = h.currentVersion - 1
  while result >= 1 and h.tags[result - 1] == curTag:
    dec result

proc redoTargetPos(h: HistoryManager): int =
  ## End of the next step after the cursor; jumping there replays a whole
  ## grouped action at once
  let total = h.log.len(h.genStream())
  if h.currentVersion >= total:
    return total
  var r = h.currentVersion + 1
  if r <= total:
    let nextRunTag = h.tags[r - 1]
    while r <= total and h.tags[r - 1] == nextRunTag:
      inc r
  result = r - 1

# --- cursor ---

proc canUndo*(h: HistoryManager): bool =
  ## True when stepping back would leave the current step
  h.currentVersion > 0

proc canRedo*(h: HistoryManager): bool =
  ## True when stepping forward would reach recorded entries
  h.currentVersion < h.log.len(h.genStream())

proc contentOfEntry(e: HistoryEntry, tsUnix: int64): HistoryContent =
  case e.kind
  of ekSnapshot:
    HistoryContent(tsUnix: tsUnix, kind: ekSnapshot, text: e.content)
  of ekDiff:
    HistoryContent(tsUnix: tsUnix, kind: ekDiff, diffOffset: e.offset,
      diffDeleted: e.deletedLen, diffInserted: e.inserted)
  of ekJson:
    HistoryContent(tsUnix: tsUnix, kind: ekJson, jsonData: e.data)
  of ekJsonPatch:
    HistoryContent(tsUnix: tsUnix, kind: ekJsonPatch,
      patchForward: e.fwdOps, patchBackward: e.bwdOps)

proc contentAt(h: HistoryManager, pos: int): Option[HistoryContent] =
  let rec = h.log.get(h.genStream(), uint64(pos))
  if rec.isNone:
    return none(HistoryContent)
  let (e, _) = decodeRecord(rec.get().payload)
  some(contentOfEntry(e, rec.get().tsUnix))

proc peekUndo*(h: HistoryManager): Option[HistoryContent] =
  ## Returns what `undo()` would return, without moving the cursor
  h.flushAuto()
  if not h.canUndo:
    return none(HistoryContent)
  let leftRec = h.log.get(h.genStream(), uint64(h.currentVersion))
  if leftRec.isSome:
    let (e, _) = decodeRecord(leftRec.get().payload)
    if e.kind == ekJsonPatch:
      # leaving a patch step surfaces that patch so callers can apply its
      # backward operations
      return some(contentOfEntry(e, leftRec.get().tsUnix))
  h.contentAt(h.undoTargetPos())

proc peekRedo*(h: HistoryManager): Option[HistoryContent] =
  ## Returns what `redo()` would return, without moving the cursor
  h.flushAuto()
  if not h.canRedo:
    return none(HistoryContent)
  h.contentAt(h.redoTargetPos())

proc undo*(h: HistoryManager): Option[HistoryContent] =
  ## Steps back one undoable step. When the step being left holds JSON
  ## Patch operations, that patch is returned (apply `patchBackward`);
  ## otherwise the entry at the new cursor position is returned. Returns
  ## `none` when stepping onto the pristine state.
  h.flushAuto()
  if not h.canUndo:
    return none(HistoryContent)
  let leftPos = h.currentVersion
  h.currentVersion = h.undoTargetPos()
  h.saveMeta()
  let leftRec = h.log.get(h.genStream(), uint64(leftPos))
  if leftRec.isSome:
    let (e, _) = decodeRecord(leftRec.get().payload)
    if e.kind == ekJsonPatch:
      return some(contentOfEntry(e, leftRec.get().tsUnix))
  h.contentAt(h.currentVersion)

proc redo*(h: HistoryManager): Option[HistoryContent] =
  ## Steps forward one redoable step. When the cursor lands on an entry
  ## holding JSON Patch operations, that patch is returned (apply
  ## `patchForward`); otherwise the landed entry itself is returned.
  ## Returns `none` when already at the newest state.
  h.flushAuto()
  if not h.canRedo:
    return none(HistoryContent)
  h.currentVersion = h.redoTargetPos()
  h.saveMeta()
  h.contentAt(h.currentVersion)

proc undoText*(h: HistoryManager): Option[string] =
  ## Undo typed for snapshot histories; `none` if the target is not a snapshot
  let content = h.undo()
  if content.isSome and content.get().kind == ekSnapshot:
    some(content.get().text)
  else:
    none(string)

proc undoJson*(h: HistoryManager): Option[JsonNode] =
  ## Undo typed for JSON histories; `none` if the target is not JSON
  let content = h.undo()
  if content.isSome and content.get().kind == ekJson:
    some(content.get().jsonData)
  else:
    none(JsonNode)

# --- selective restore ---

proc restoreTo*(h: HistoryManager, pos: int) =
  ## Moves the cursor to `pos` (0 = pristine, `pos = N` = after the Nth
  ## entry) discarding everything newer. Equivalent to repeated undos or
  ## redos in one rotation. Positional: it counts entries, not steps.
  h.flushAuto()
  let n = h.log.len(h.genStream())
  if pos < 0 or pos > n:
    raise newException(HistoryError,
      "restoreTo position out of range: " & $pos)
  if pos == h.currentVersion:
    return
  if pos < h.currentVersion:
    h.rotateGeneration(1, pos)
    h.currentVersion = pos
  else:
    h.currentVersion = pos
  h.saveMeta()

# --- maintenance ---

proc compact*(h: HistoryManager) =
  ## Rewrites this history's WAL file keeping exactly the live entries of the
  ## active generation (timestamps preserved), then reopens it. Old
  ## generations and orphaned bytes are dropped from disk. No-op for
  ## in-memory histories. Raises inside an open group.
  if h.basePath.len == 0:
    return
  h.flushAuto()
  if h.inGroup:
    raise newException(HistoryError, "cannot compact inside a group")
  if h.log.len(h.genStream()) == 0:
    return

  var payloads: seq[(string, int64)]
  for rec in h.log.forward(h.genStream()):
    payloads.add((rec.payload, rec.tsUnix))

  h.log.close()

  let tmpName = h.historyId & "_compacting"
  block:
    var tmp = openLogStore(h.basePath, tmpName, cacheCapacity = 0)
    let dstStream = h.historyId & ":g0"
    for (p, ts) in payloads:
      discard tmp.append(dstStream, p, tsUnix = ts, sync = false)
    tmp.close()

  let oldWal = h.basePath / (h.historyId & ".wal")
  if fileExists(oldWal):
    removeFile(oldWal)
  moveFile(h.basePath / (tmpName & ".wal"), oldWal)

  h.log = openLogStore(h.basePath, h.historyId,
    cacheCapacity = h.cacheCapacity)
  h.gen = 0
  h.rebuildTags()
  h.saveMeta()

# --- lifecycle ---

proc close*(h: HistoryManager) =
  ## Flushes pending auto-grouped entries and releases the underlying store
  h.flushAuto()
  h.log.close()
