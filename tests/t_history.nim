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

  test "push after undo":
    var h = newHistoryManager(root, "snap4")
    h.pushSnapshot("a")
    h.pushSnapshot("b")
    h.pushSnapshot("c")

    discard h.undo()
    discard h.undo()
    check h.canUndo()

    h.pushSnapshot("d")
    # after push, we're at the end; canRedo depends on log length
    check not h.canRedo()

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

    # after endGroup, we're at pos 4 (entry "c")
    # undo returns entry at pos 3 ("b")
    let c = h.undo()
    check c.isSome
    check c.get().kind == ekDiff
    check c.get().diffInserted == "b"

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
