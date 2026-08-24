import std/[unittest, os, json, times, strformat, strutils, monotimes]
import undo/history

## Benchmarks in the style of boogie's test suites. Run with
## `nimble test -d:release` (or `clue test --release`) for meaningful numbers.

proc benchRoot(): string =
  let base = "tests" / "data"
  if not dirExists(base):
    createDir(base)
  result = base / ("undo_bench_" & $getTime().toUnix())
  createDir(result)

template bench(name: string, ops: int, body: untyped) =
  let t0 = getMonoTime()
  body
  let secs = float((getMonoTime() - t0).inNanoseconds) / 1e9
  let rate = float(ops) / max(secs, 1e-9)
  echo "[bench][undo] ", name, ": ", align($rate.int64, 12), " ops/s"
  check ops > 0

suite "History benchmarks":

  test "in-memory push throughput (snapshot / diff / json)":
    const N = 100_000
    var h = newInMemoryHistoryManager("bench_push")
    bench("mem push snapshot", N):
      for i in 1 .. N:
        h.pushSnapshot("snapshot payload number " & $i)
    h.close()

    var h2 = newInMemoryHistoryManager("bench_push_diff")
    bench("mem push diff", N):
      for i in 1 .. N:
        h2.pushDiff(i mod 64, 1, "x")
    h2.close()

    var h3 = newInMemoryHistoryManager("bench_push_json")
    const M = 20_000
    bench("mem push json (small doc)", M):
      for i in 1 .. M:
        h3.pushJson(%*{"id": i, "x": i mod 97, "tag": "obj"})
    h3.close()

  test "disk push throughput":
    const N = 20_000
    var h = newHistoryManager(benchRoot(), "bench_disk",
        cacheCapacity = 1024)
    bench("disk push snapshot", N):
      for i in 1 .. N:
        h.pushSnapshot("snapshot payload number " & $i)
    h.close()

  test "undo/redo stepping throughput":
    const N = 50_000
    var h = newInMemoryHistoryManager("bench_step")
    for i in 1 .. N:
      h.pushSnapshot("s" & $i)

    var steps = 0
    bench("mem undo/redo step pair", N):
      while h.canUndo():
        discard h.undo()
        inc steps
        if steps >= N:
          break
    check not h.canUndo()

    var redoSteps = 0
    bench("mem redo step", N):
      while h.canRedo():
        discard h.redo()
        inc redoSteps
    check redoSteps == N
    h.close()

  test "divergent push (generation rotation) cost":
    const Prefix = 5_000
    const Rounds = 500
    var h = newInMemoryHistoryManager("bench_diverge")
    for i in 1 .. Prefix:
      h.pushSnapshot("p" & $i)

    bench("divergent push after undo", Rounds):
      for i in 1 .. Rounds:
        discard h.undo()
        h.pushSnapshot("d" & $i)
    h.close()

  test "json patch push throughput":
    const N = 10_000
    var h = newInMemoryHistoryManager("bench_patch")
    var prev = %*{"counter": 0}
    var doc = %*{"counter": 0}
    h.pushJson(prev)
    bench("mem push jsonDiff", N):
      for i in 1 .. N:
        doc["counter"] = %(doc["counter"].getInt() + 1)
        h.pushJsonDiff(prev, doc)
        prev = doc.copy()
    check h.canUndo()
    h.close()

  test "compaction cost at moderate size":
    const N = 10_000
    let dir = benchRoot()
    block:
      var h = newHistoryManager(dir, "bench_compact")
      for i in 1 .. N:
        h.pushSnapshot("c" & $i)
      discard h.undo()
      h.pushSnapshot("tail")   # divergent: leaves one orphaned generation
      h.close()

    block:
      var h = newHistoryManager(dir, "bench_compact")
      bench("compact 10k-entry history", 1):
        h.compact()
      check h.canUndo()
      h.close()
