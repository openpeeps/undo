import std/[unittest, os, json, options, times]
import undo/history

proc testRoot(): string =
  let base = "tests" / "data"
  if not dirExists(base):
    createDir(base)
  result = base / ("undo_tests_" & $getTime().toUnix())
  createDir(result)

suite "Snapshot history":

  let root = testRoot()

  test "push and undo":
    var h = newHistoryManager(root, "snap1")
    h.pushSnapshot("hello")
    h.pushSnapshot("world")
    check h.canUndo()
    check not h.canRedo()

    # undo returns state at new position (convention 2)
    let content = h.undo()
    check content.isSome
    check content.get().kind == ekSnapshot
    check content.get().text == "hello"
    check h.canRedo()

  test "redo after undo":
    var h = newHistoryManager(root, "snap2")
    h.pushSnapshot("a")
    h.pushSnapshot("b")
    h.pushSnapshot("c")

    discard h.undo()
    discard h.undo()
    check h.canRedo()

    let content = h.redo()
    check content.isSome
    check content.get().text == "b"

  test "canUndo/canRedo edge cases":
    var h = newHistoryManager(root, "snap3")
    check not h.canUndo()
    check not h.canRedo()

    h.pushSnapshot("first")
    check h.canUndo()
    check not h.canRedo()

    discard h.undo()
    check not h.canUndo()
    check h.canRedo()

  test "multiple undo/redo cycles":
    var h = newHistoryManager(root, "snap5")
    for i in 1..5:
      h.pushSnapshot("state" & $i)

    # undo 4 times (5th undo goes to pos 0, no entry there)
    for i in countdown(4, 1):
      let c = h.undo()
      check c.isSome
      check c.get().text == "state" & $i

    # at pos 1, canUndo is true (can go to pos 0)
    check h.canUndo()
    discard h.undo()
    check not h.canUndo()

    # redo 5 times back to pos 5
    for i in 1..5:
      let c = h.redo()
      check c.isSome
      check c.get().text == "state" & $i

    check not h.canRedo()

suite "Truncation on divergent push":

  let root = testRoot()

  test "push after undo discards the undone future":
    var h = newHistoryManager(root, "trunc1")
    h.pushSnapshot("a")
    h.pushSnapshot("b")
    h.pushSnapshot("c")

    discard h.undo()
    discard h.undo()   # cursor at "a"

    h.pushSnapshot("d")   # b and c are now unreachable
    check not h.canRedo()

    # walking back must yield only live entries: d, a
    let c1 = h.undo()
    check c1.isSome
    check c1.get().text == "a"
    discard h.undo()   # step onto pristine position 0
    check not h.canUndo()

  test "full walk after divergence contains no orphans":
    var h = newHistoryManager(root, "trunc2")
    for ch in ["a", "b", "c", "e"]:
      h.pushSnapshot(ch)
    discard h.undo()   # cursor at "c"
    discard h.undo()   # cursor at "b"

    h.pushSnapshot("d")
    check not h.canRedo()

    var seen: seq[string]
    while true:
      let c = h.undo()
      if c.isNone: break
      seen.add(c.get().text)
    check seen == @["b", "a"]
    check not h.canUndo()

    var fwd: seq[string]
    while h.canRedo():
      let c = h.redo()
      check c.isSome
      fwd.add(c.get().text)
    check fwd == @["a", "b", "d"]

  test "grouped pushes after undo also truncate":
    var h = newHistoryManager(root, "trunc3")
    h.pushSnapshot("base")
    h.pushSnapshot("draft")
    discard h.undo()   # cursor at "base"

    h.beginGroup()
    h.pushDiff(0, 0, "x")
    h.pushDiff(1, 0, "y")
    h.endGroup()

    check not h.canRedo()
    # the drained group is one step; undo lands back on "base"
    let c = h.undo()
    check c.isSome
    check c.get().kind == ekSnapshot
    check c.get().text == "base"

suite "maxVersions soft cap":

  let root = testRoot()

  test "cap prunes oldest entries once threshold exceeded":
    var h = newHistoryManager(root, "cap1", maxVersions = 5)
    for i in 1..12:
      h.pushSnapshot("state" & $i)

    # rotation triggers past 2*cap=10 keeping newest 5, then one more push:
    # live window is state7..state12
    check not h.canRedo()
    var seen: seq[string]
    while true:
      let c = h.undo()
      if c.isNone: break
      seen.add(c.get().text)
    check seen == @["state11", "state10", "state9", "state8", "state7"]
    check not h.canUndo()

  test "in-memory cap behaves identically":
    var h = newInMemoryHistoryManager("capmem", maxVersions = 3)
    for i in 1..9:
      h.pushSnapshot("m" & $i)
    # rotation at n>6 keeps m5..m7; m8, m9 grow the soft window to 5
    var seen: seq[string]
    while true:
      let c = h.undo()
      if c.isNone: break
      seen.add(c.get().text)
    check seen == @["m8", "m7", "m6", "m5"]
    check not h.canUndo()

suite "Peek APIs":

  let root = testRoot()

  test "peekUndo previews without moving the cursor":
    var h = newHistoryManager(root, "peek1")
    h.pushSnapshot("a")
    h.pushSnapshot("b")
    h.pushSnapshot("c")

    let p1 = h.peekUndo()
    check p1.isSome
    check p1.get().text == "b"

    let p2 = h.peekUndo()
    check p2.isSome
    check p2.get().text == "b"

    check h.canRedo() == false   # still at tail

    let c = h.undo()
    check c.isSome
    check c.get().text == "b"   # matches preview

  test "peekRedo previews without moving the cursor":
    var h = newHistoryManager(root, "peek2")
    h.pushSnapshot("a")
    h.pushSnapshot("b")

    discard h.undo()
    let p = h.peekRedo()
    check p.isSome
    check p.get().text == "b"
    check h.canUndo()   # cursor unmoved

    let c = h.redo()
    check c.isSome
    check c.get().text == "b"

  test "peeks return none at history bounds":
    var h = newHistoryManager(root, "peek3")
    check h.peekUndo().isNone
    check h.peekRedo().isNone
    h.pushSnapshot("only")
    check h.peekRedo().isNone

suite "Timestamps":

  let root = testRoot()

  test "returned content carries its record timestamp":
    var h = newInMemoryHistoryManager("ts1")
    let before = getTime().toUnix()
    h.pushSnapshot("stamped")
    h.pushSnapshot("stamped2")
    let c = h.undo()   # lands on "stamped" at position 1
    check c.isSome
    check c.get().tsUnix >= before
    check c.get().tsUnix <= getTime().toUnix()

suite "Compaction":

  let root = testRoot()

  test "compact drops orphaned data and preserves live state":
    let dbPath = root / "cmp"
    block:
      var h = newHistoryManager(dbPath, "cmp1")
      h.pushSnapshot("s1")
      h.pushSnapshot("s2")
      h.pushSnapshot("s3")
      discard h.undo()          # cursor at s2
      h.pushSnapshot("s4")      # divergent: live = s1, s2, s4
      h.close()

    block:
      var h = newHistoryManager(dbPath, "cmp1")
      h.compact()

      check not h.canRedo()
      let c4 = h.undo()
      check c4.isSome
      check c4.get().text == "s2"
      let c1 = h.undo()
      check c1.isSome
      check c1.get().text == "s1"
      discard h.undo()   # onto pristine position 0
      check not h.canUndo()

      check h.redo().get().text == "s1"
      check h.redo().get().text == "s2"
      check h.redo().get().text == "s4"
      check not h.canRedo()
      h.close()

    block:
      var h = newHistoryManager(dbPath, "cmp1")
      check h.canUndo()
      check not h.canRedo()   # previous block ended at the tail
      check h.undoText().get() == "s2"
      h.close()

  test "timestamps survive compaction":
    var h = newInMemoryHistoryManager("noop")   # in-memory: no-op path
    h.compact()   # must be a safe no-op
    h.pushJson(%*{"k": true})
    h.pushJson(%*{"k": false})
    check h.undoJson().isSome

suite "Diff history":

  let root = testRoot()

  test "push and undo diff":
    var h = newHistoryManager(root, "diff1")
    h.pushDiff(0, 0, "hello")
    h.pushDiff(5, 0, " world")

    let content = h.undo()
    check content.isSome
    check content.get().kind == ekDiff
    check content.get().diffOffset == 0
    check content.get().diffDeleted == 0
    check content.get().diffInserted == "hello"

  test "redo diff":
    var h = newHistoryManager(root, "diff2")
    h.pushDiff(0, 0, "abc")
    h.pushDiff(3, 0, "def")

    discard h.undo()
    let content = h.redo()
    check content.isSome
    check content.get().diffInserted == "def"

suite "JSON history":

  let root = testRoot()

  test "push and undo json":
    var h = newHistoryManager(root, "json1")
    let state1 = %*{"name": "box", "x": 10, "y": 20}
    let state2 = %*{"name": "box", "x": 50, "y": 60}
    h.pushJson(state1)
    h.pushJson(state2)

    let content = h.undo()
    check content.isSome
    check content.get().kind == ekJson
    check content.get().jsonData["name"].getStr() == "box"
    check content.get().jsonData["x"].getInt() == 10

  test "redo json":
    var h = newHistoryManager(root, "json2")
    h.pushJson(%*{"a": 1})
    h.pushJson(%*{"a": 2})

    discard h.undo()
    let content = h.redo()
    check content.isSome
    check content.get().jsonData["a"].getInt() == 2

  test "multiple json undos":
    var h = newHistoryManager(root, "json3")
    h.pushJson(%*{"type": "rect", "w": 100})
    h.pushJson(%*{"type": "circle", "r": 50})
    h.pushJson(%*{"type": "text", "content": "hello"})

    let c2 = h.undo()
    check c2.isSome
    check c2.get().jsonData["type"].getStr() == "circle"

    let c1 = h.undo()
    check c1.isSome
    check c1.get().jsonData["type"].getStr() == "rect"

suite "Mixed entry types":

  let root = testRoot()

  test "snapshot then diff then json":
    var h = newHistoryManager(root, "mixed1")
    h.pushSnapshot("initial")
    h.pushDiff(7, 0, " content")
    h.pushJson(%*{"version": 3})

    let j = h.undo()
    check j.isSome
    check j.get().kind == ekDiff

    let s = h.undo()
    check s.isSome
    check s.get().kind == ekSnapshot
    check s.get().text == "initial"

suite "Grouping":

  let root = testRoot()

  test "beginGroup batches operations":
    var h = newHistoryManager(root, "grp1")
    h.pushSnapshot("before")
    h.beginGroup()
    h.pushDiff(0, 0, "a")
    h.pushDiff(1, 0, "b")
    h.pushDiff(2, 0, "c")
    h.endGroup()

    # the whole group is one undoable step: undo lands on "before"
    let c = h.undo()
    check c.isSome
    check c.get().kind == ekSnapshot
    check c.get().text == "before"

    # redo replays the entire group, landing on its last entry
    let r = h.redo()
    check r.isSome
    check r.get().kind == ekDiff
    check r.get().diffInserted == "c"

  test "beginGroup without endGroup raises":
    var h = newHistoryManager(root, "grp2")
    h.beginGroup()
    expect HistoryError:
      h.beginGroup()

  test "endGroup without beginGroup raises":
    var h = newHistoryManager(root, "grp3")
    expect HistoryError:
      h.endGroup()

suite "Disk persistence":

  let root = testRoot()

  test "reopen recovers state":
    let dbPath = root / "persist"
    block:
      var h = newHistoryManager(dbPath, "persist1")
      h.pushSnapshot("first")
      h.pushSnapshot("second")
      h.pushSnapshot("third")
      discard h.undo()
      h.close()

    block:
      var h = newHistoryManager(dbPath, "persist1")
      check h.canUndo()
      check h.canRedo()

      let c = h.undo()
      check c.isSome
      check c.get().text == "first"

  test "in-memory mode works":
    var h = newInMemoryHistoryManager("mem1")
    h.pushSnapshot("hello")
    h.pushSnapshot("world")
    let c = h.undo()
    check c.isSome
    check c.get().text == "hello"

suite "Convenience methods":

  let root = testRoot()

  test "undoText returns text for snapshot":
    var h = newHistoryManager(root, "conv1")
    h.pushSnapshot("hello")
    h.pushSnapshot("world")
    let t = h.undoText()
    check t.isSome
    check t.get() == "hello"

  test "undoText returns none for non-snapshot":
    var h = newHistoryManager(root, "conv2")
    h.pushJson(%*{"a": 1})
    h.pushJson(%*{"a": 2})
    let t = h.undoText()
    check t.isNone()

  test "undoJson returns json for json entry":
    var h = newHistoryManager(root, "conv3")
    h.pushJson(%*{"x": 42})
    h.pushJson(%*{"x": 99})
    let j = h.undoJson()
    check j.isSome
    check j.get()["x"].getInt() == 42

  test "undoJson returns none for non-json":
    var h = newHistoryManager(root, "conv4")
    h.pushSnapshot("text")
    h.pushSnapshot("more")
    let j = h.undoJson()
    check j.isNone()

suite "Auto-grouping":

  var fakeNow = 0'i64

  proc steppedClock(msStep: int64): NowFn =
    return proc(): int64 {.gcsafe.} =
      result = fakeNow
      fakeNow += msStep

  test "rapid pushes coalesce into a single undoable step":
    let h = newInMemoryHistoryManager("auto1", autoGroupMs = 500)
    h.setClock(steppedClock(100))   # each call advances 100ms: always in window
    h.pushSnapshot("k1")
    h.pushSnapshot("k2")
    h.pushSnapshot("k3")
    # window still open; nothing durable yet, cursor reflects queued state
    check not h.canRedo()

    discard h.undo()   # flushes the window, then jumps the whole step
    check not h.canUndo()

  test "window expiry starts a fresh step":
    let h = newInMemoryHistoryManager("auto2", autoGroupMs = 500)
    h.setClock(steppedClock(100))
    h.pushSnapshot("a")     # opens window
    h.pushSnapshot("b")     # within window -> coalesced
    fakeNow += 2000         # idle past the window
    h.pushSnapshot("c")     # commits {a,b}, opens fresh window with c

    let c1 = h.undo()       # commits {c}, exits it onto the end of {a,b}
    check c1.isSome
    check c1.get().text == "b"
    check h.canUndo()       # the coalesced step is still behind us
    discard h.undo()        # exits {a,b} onto the pristine state
    check not h.canUndo()

  test "autoGroupMax forces a step split":
    let h = newInMemoryHistoryManager("auto3", autoGroupMs = 500,
        autoGroupMax = 2)
    h.setClock(steppedClock(10))
    for i in 1 .. 5:
      h.pushSnapshot("m" & $i)   # splits at every 2 entries
    discard h.undo()
    check h.canUndo()
    discard h.undo()
    check h.canUndo()

  test "manual beginGroup drains a pending auto-window first":
    let h = newInMemoryHistoryManager("auto4", autoGroupMs = 500)
    h.setClock(steppedClock(10))
    h.pushSnapshot("solo")
    h.beginGroup()          # drains {solo} as its own committed step
    h.pushDiff(0, 0, "x")
    h.endGroup()
    # two steps exist: {solo} and the manual group
    let g = h.undo()        # exits the group step onto the prior step's end
    check g.isSome
    check g.get().kind == ekSnapshot
    check g.get().text == "solo"
    check h.canUndo()
    discard h.undo()        # exits {solo} onto pristine
    check not h.canUndo()

suite "JSON Patch":

  let root = testRoot()

  test "pushJsonDiff stores forward+inverse op sets":
    var h = newInMemoryHistoryManager("patch1")
    let s1 = %*{"name": "box", "x": 10}
    let s2 = %*{"name": "box", "x": 50, "y": 20}
    let s3 = %*{"name": "box", "x": 50, "y": 20, "z": 5}
    # no baseline push needed: the app holds s1 and records deltas only
    h.pushJsonDiff(s1, s2)
    h.pushJsonDiff(s2, s3)

    # undo surfaces the patch being left: s3 -> s2
    let back = h.undo()
    check back.isSome
    check back.get().kind == ekJsonPatch
    check applyOps(s3, back.get().patchBackward) == s2

    # successive undo chains cleanly through the earlier delta: s2 -> s1
    let back2 = h.undo()
    check back2.isSome
    check back2.get().kind == ekJsonPatch
    check applyOps(s2, back2.get().patchBackward) == s1
    check not h.canUndo()

    # redo re-enters the first delta: s1 -> s2
    let fwd = h.redo()
    check fwd.isSome
    check fwd.get().kind == ekJsonPatch
    check applyOps(s1, fwd.get().patchForward) == s2

    let fwd2 = h.redo()
    check fwd2.isSome
    check applyOps(s2, fwd2.get().patchForward) == s3
    check not h.canRedo()

  test "jsonDiff inverse algebra on the earlier delta":
    let s1 = %*{"name": "box", "x": 10}
    let s2 = %*{"name": "box", "x": 50, "y": 20}
    let (fwd, bwd) = jsonDiff(s1, s2)
    check fwd.len == 2           # replace /x, add /y
    check applyOps(s1, fwd) == s2
    check applyOps(applyOps(s2, bwd), fwd) == s2

  test "nested object diffs produce minimal ops":
    var h = newInMemoryHistoryManager("patch2")
    let s1 = %*{"a": {"b": {"c": 1}}, "keep": true}
    let s2 = %*{"a": {"b": {"c": 2}}, "keep": true}
    let (fwd, bwd) = jsonDiff(s1, s2)
    check fwd.len == 1   # single replace at /a/b/c
    check fwd[0].path == "/a/b/c"
    check bwd.len == 1
    check applyOps(s1, fwd) == s2
    check applyOps(s2, bwd) == s1

  test "arrays are replaced atomically":
    let s1 = %*{"items": [1, 2, 3]}
    let s2 = %*{"items": [1, 2]}
    let (fwd, _) = jsonDiff(s1, s2)
    check fwd.len == 1
    check fwd[0].path == "/items"
    check fwd[0].op == jpoReplace

  test "pointer escaping handles ~ and / in keys":
    let s1 = %*{"weird/key~name": 1}
    let s2 = %*{"weird/key~name": 2}
    let (fwd, bwd) = jsonDiff(s1, s2)
    check fwd[0].path == "/weird~1key~0name"
    check applyOps(s1, fwd) == s2
    check applyOps(s2, bwd) == s1

  test "pushJsonPatch stores caller-supplied operations":
    var h = newInMemoryHistoryManager("patch3")
    let doc = %*{"v": 1}
    h.pushJson(doc)   # baseline
    let ops = @[JsonOp(op: jpoReplace, path: "/v",
      value: %2)]
    let inverse = @[JsonOp(op: jpoReplace, path: "/v",
      value: %1)]
    h.pushJsonPatch(ops, inverse)

    # undo surfaces the patch being left; its backward ops revert the edit
    let c = h.undo()
    check c.isSome
    check c.get().kind == ekJsonPatch
    check applyOps(%*{"v": 2}, c.get().patchBackward)["v"].getInt() == 1

  test "applyOps array insert and append token":
    let doc = %*{"list": [1, 3]}
    let grown = applyOps(doc, @[
      JsonOp(op: jpoAdd, path: "/list/1", value: %2),
      JsonOp(op: jpoAdd, path: "/list/-", value: %4)
    ])
    check grown["list"].len == 4
    check grown["list"][0].getInt() == 1
    check grown["list"][1].getInt() == 2
    check grown["list"][3].getInt() == 4

  test "applyOps raises on missing targets":
    expect HistoryError:
      discard applyOps(%*{"a": 1}, @[
        JsonOp(op: jpoRemove, path: "/missing")])
    expect HistoryError:
      discard applyOps(%*{"a": 1}, @[
        JsonOp(op: jpoReplace, path: "/missing", value: %9)])

suite "RestoreTo":

  let root = testRoot()

  test "backward restore truncates the future":
    var h = newInMemoryHistoryManager("rt1")
    for ch in ["a", "b", "c"]:
      h.pushSnapshot(ch)
    h.restoreTo(2)          # keep a, b
    check not h.canRedo()
    check h.canUndo()
    check h.undoText().get() == "a"
    discard h.undo()
    check not h.canUndo()

  test "forward restore replays silently":
    var h = newInMemoryHistoryManager("rt2")
    for ch in ["a", "b", "c"]:
      h.pushSnapshot(ch)
    discard h.undo()        # cursor at b
    h.restoreTo(3)
    check not h.canRedo()
    check h.canUndo()       # tail is not pristine
    check h.peekUndo().get().text == "b"

  test "restore to pristine clears everything":
    var h = newInMemoryHistoryManager("rt3")
    h.pushSnapshot("x")
    h.restoreTo(0)
    check not h.canUndo()
    check not h.canRedo()

  test "out-of-range positions raise":
    var h = newInMemoryHistoryManager("rt4")
    h.pushSnapshot("x")
    expect HistoryError:
      h.restoreTo(5)
    expect HistoryError:
      h.restoreTo(-1)

  test "restoreTo persists across reopen":
    let dbPath = root / "rtpersist"
    block:
      var h = newHistoryManager(dbPath, "rtp")
      for ch in ["a", "b", "c"]:
        h.pushSnapshot(ch)
      h.restoreTo(2)
      h.close()
    block:
      var h = newHistoryManager(dbPath, "rtp")
      check not h.canRedo()
      check h.undoText().get() == "a"
      h.close()
