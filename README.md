<p align="center">
  Undo/Redo History Manager in Nim
</p>

<p align="center">
  <code>nimble install undo</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/undo">API reference</a><br>
  <img src="https://github.com/openpeeps/undo/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/undo/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About

`undo` is a persistent history manager for Nim applications. It records changes to text documents or structured (JSON) documents and lets higher level apps, such as text editors, design tools, or any stateful application, walk back and forth through their change history with `undo()` and `redo()`.

Every entry is appended to a durable log powered by [boogie](https://github.com/openpeeps/boogie)'s `LogStore` (write-ahead log with group commits and crash recovery). Entries are serialized with Fast Binary Encoding ([openparser/fbe](https://github.com/openpeeps/openparser)), so histories survive application restarts.

Three kinds of entries are supported:

| Entry kind | What it stores | Typical use |
|---|---|---|
| Snapshot | Full document content | Small documents, checkpoints |
| Diff | Offset, deleted length, inserted text | Large documents, keystroke-level tracking |
| JSON | Full serialized JSON state | UI designers, structured editors |

Multiple operations can be batched into a single undoable step with `beginGroup` / `endGroup`, which is handy for coalescing bursts of typing or multi-object edits into one history step.

## 😍 Key Features
- Four entry kinds: snapshots, text diffs, JSON states, and JSON Patch deltas
- Persistent by default (WAL-backed), with an in-memory mode for testing
- Operation grouping, manual or automatic (idle-time coalescing), into single undoable steps
- Linear cursor model: `canUndo` / `canRedo` / `undo` / `redo`
- Typed convenience accessors: `undoText` and `undoJson`
- Standard editor semantics: pushing after an undo discards the undone future
- Optional history depth cap (`maxVersions`) with amortized pruning
- `compact()` rebuilds the log file keeping only live entries
- Non-destructive previews via `peekUndo` / `peekRedo`
- Selective cursor jumps with `restoreTo`
- Per-entry Unix timestamps exposed on returned content

## Examples

Every example below assumes:

```nim
import std/[json, options]
import undo
```

### Snapshots

Record the full content of a document at each step:

```nim
var h = newHistoryManager("data/history", "mydoc")

h.pushSnapshot("hello")
h.pushSnapshot("hello world")

let prev = h.undo()          # some(HistoryContent)
echo prev.get().text         # "hello"

let next = h.redo()          # some(HistoryContent)
echo next.get().text         # "hello world"

doAssert h.canUndo()
doAssert not h.canRedo()
```

### Diffs

For large documents, record only what changed. The caller supplies the offset, the number of deleted characters, and the inserted text:

```nim
h.pushDiff(0, 0, "hello")        # insert "hello" at 0
h.pushDiff(5, 0, " world")       # insert " world" at 5

let c = h.undo()
echo c.get().diffInserted        # "hello"
```

### JSON documents

For structured apps (UI designers, diagram tools), record full JSON states:

```nim
h.pushJson(%*{"type": "rect", "x": 10, "y": 20})
h.pushJson(%*{"type": "rect", "x": 50, "y": 60})

let c = h.undo()
echo c.get().jsonData["x"].getInt()   # 10
```

Mixed histories are fine: snapshots, diffs, and JSON entries can coexist in one history. Use the unified `HistoryContent` variant returned by `undo` / `redo` and dispatch on its `kind`.

### Grouping operations

Batch several pushes into a single undoable step. `undo` jumps across the whole group at once, and `redo` replays it entirely, just like a real editor:

```nim
h.pushSnapshot("before")
h.beginGroup()
h.pushDiff(0, 0, "a")
h.pushDiff(1, 0, "b")
h.pushDiff(2, 0, "c")
h.endGroup()

let c = h.undo()
echo c.get().text        # "before" (the whole group left in one step)
let r = h.redo()
echo r.get().diffInserted   # "c" (redo lands on the group's last entry)
```

### Auto-grouping

Real editors coalesce bursts of typing into one undo step automatically. Pass `autoGroupMs` to enable the same behavior: pushes arriving within the idle window join the current step; a pause longer than the window starts a new one:

```nim
# keystrokes within 700ms of each other become one undo step
var h = newHistoryManager("data/history", "mydoc", autoGroupMs = 700)

h.pushDiff(0, 0, "H")
h.pushDiff(1, 0, "i")     # joins the same step
discard h.undo()          # removes "Hi" in one jump
```

Tuning knobs:

| Parameter | Default | Meaning |
|---|---|---|
| `autoGroupMs` | `0` (off) | Idle window in milliseconds; pushes closer than this coalesce |
| `autoGroupMax` | `64` | Hard cap on entries queued per window; exceeding it splits the step |

Pending entries commit when the window expires or when any read (`undo`, `peek*`, ...), `beginGroup`, `close`, or `compact` runs, so half-formed steps are never observable through the API.

### JSON Patch deltas

For structured documents, record deltas instead of full states with `pushJsonDiff`. It computes RFC 6902-style forward and inverse operation sets (JSON Pointer paths), so undo stays self-contained without storing snapshots. The practical pattern keeps the previous state alongside your working document:

```nim
var prev = %*{"widgets": [{"type": "rect", "x": 10}]}
h.pushJson(prev)                  # baseline state

# on every change:
var next = prev.copy()
next["widgets"][0]["x"] = %50     # ...apply your real edit here
h.pushJsonDiff(prev, next)
prev = next
```

Walking history returns whichever entry the step transition touched. When leaving or entering a patch entry you get its operations; apply the direction matching the way you stepped:

```nim
let c = h.undo()                  # left a patch step: it hands back that patch
if c.get().kind == ekJsonPatch:
  doc = applyOps(doc, c.get().patchBackward)
elif c.get().kind == ekJson:
  doc = c.get().jsonData          # landed on a recorded JSON state

let r = h.redo()
if r.get().kind == ekJsonPatch:
  doc = applyOps(doc, r.get().patchForward)
```

Operations are plain data, so you can supply your own instead of diffing:

```nim
h.pushJsonPatch(
  @[JsonOp(op: jpoReplace, path: "/title", value: %"new")],
  @[JsonOp(op: jpoReplace, path: "/title", value: %"old")]
)
```

Supported v1 scope: `add`, `remove`, and `replace` over JSON Pointer paths, array indexing including `-` append, plus `~`/`/` key escaping. Arrays themselves diff atomically (whole-array replace); `move`, `copy`, `test`, and LCS-based array diffing are future work.

### Restoring to a position

Jump the cursor anywhere in one call. Everything newer is discarded exactly as if you had pressed undo that many times:

```nim
for i in 1 .. 10:
  h.pushSnapshot("v" & $i)

h.restoreTo(4)            # keep the first four entries
doAssert not h.canRedo()

h.restoreTo(0)            # pristine state, nothing applied
doAssert not h.canUndo()
```

### Truncation after undo

Pushing while the cursor sits behind the tail discards the undone future, exactly like a text editor. The discarded entries can never be reached again by `undo` or `redo`:

```nim
h.pushSnapshot("a")
h.pushSnapshot("b")
h.pushSnapshot("c")

discard h.undo()
discard h.undo()        # cursor at "a"

h.pushSnapshot("d")     # "b" and "c" are gone for good
doAssert not h.canRedo()   # d is now the newest state

let c = h.undo()
echo c.get().text       # "a", not "b"
```

Under the hood this rotates the history to a fresh generation stream holding only live entries, so logical positions stay equal to physical sequence numbers and orphaned data stays unreachable.

### Capping history depth

Pass `maxVersions` to keep only recent history. The cap is soft: pruning triggers once the stream grows past twice the cap and keeps the newest `maxVersions` entries, which amortizes the cost to O(1) per push instead of copying on every keystroke:

```nim
var h = newHistoryManager("data/history", "mydoc", maxVersions = 500)
for i in 1 .. 10_000:
  h.pushSnapshot("edit " & $i)

# only roughly the last 500..1000 entries remain reachable
while h.canUndo():
  discard h.undoText()
```

### Peeking without moving

`peekUndo` and `peekRedo` report what the next step would return without touching the cursor. Useful for enabling menu items with labels like "Undo typing":

```nim
let upcoming = h.peekUndo()
if upcoming.isSome:
  echo upcoming.get().text    # what undo() would land on
doAssert h.canUndo()

let again = h.peekUndo()       # same answer; cursor never moved
doAssert again.get().text == upcoming.get().text
```

### Entry timestamps

Every record is stamped when it is pushed, and `undo`, `redo`, and both peeks return that stamp on `HistoryContent.tsUnix` (seconds since epoch):

```nim
h.pushSnapshot("stamped")
let c = h.undo()
echo c.get().tsUnix            # e.g. 1787559084
```

### Compaction

Histories are append-only, so old generations and pruned entries linger in the WAL file until compaction. `compact()` rewrites the log keeping exactly the live entries (timestamps preserved) and reopens it. It is a safe no-op for in-memory histories:

```nim
h.compact()
```

### Persistence and recovery

Histories are durable across restarts. Reopening the same path restores the cursor position:

```nim
block:
  var h = newHistoryManager("data/history", "mydoc")
  h.pushSnapshot("first")
  h.pushSnapshot("second")
  h.pushSnapshot("third")
  discard h.undo()
  h.close()

block:
  var h = newHistoryManager("data/history", "mydoc")
  doAssert h.canUndo()
  doAssert h.canRedo()
  let c = h.undo()
  echo c.get().text    # "first"
```

### In-memory mode

For tests or ephemeral use, skip the disk entirely:

```nim
var h = newInMemoryHistoryManager("session")
h.pushSnapshot("temporary")
```

## API overview

| Proc | Description |
|---|---|
| `newHistoryManager(path, historyId, maxVersions = 0, autoGroupMs = 0)` | Opens or creates a disk-backed history; `maxVersions` softly caps depth, `autoGroupMs` enables idle-window coalescing |
| `newInMemoryHistoryManager(historyId)` | Creates an ephemeral in-memory history |
| `pushSnapshot(content)` | Records a full text snapshot |
| `pushDiff(offset, deletedLen, inserted)` | Records a text diff |
| `pushJson(data)` | Records a full JSON state |
| `pushJsonDiff(prevState, newState)` | Diffs two JSON states and records forward + inverse patch ops |
| `pushJsonPatch(ops, inverse)` | Records caller-supplied patch operations |
| `beginGroup` / `endGroup` | Batches pushes into one undoable step |
| `undo(): Option[HistoryContent]` | Steps back one undoable step; surfaces the exited patch or the landed state |
| `redo(): Option[HistoryContent]` | Steps forward one redoable step; surfaces the entered patch or the landed state |
| `peekUndo(): Option[HistoryContent]` | Previews the next undo without moving the cursor |
| `peekRedo(): Option[HistoryContent]` | Previews the next redo without moving the cursor |
| `undoText(): Option[string]` | Undo typed as a snapshot string |
| `undoJson(): Option[JsonNode]` | Undo typed as a JSON node |
| `restoreTo(pos)` | Jumps the cursor to an absolute position, discarding newer entries |
| `canUndo(): bool` / `canRedo(): bool` | Cursor availability checks |
| `applyOps(doc, ops): JsonNode` | Applies RFC 6902-style operations to a JSON document |
| `jsonDiff(prev, next): (fwd, bwd)` | Computes forward + inverse operation sets between two JSON states |
| `compact()` | Rewrites the log file keeping only live entries |
| `close()` | Flushes pending entries and closes the underlying store |

Every returned `HistoryContent` carries `tsUnix`, the Unix timestamp (seconds) stamped when the entry was recorded.

> [!NOTE]
> `undo` is built on [boogie](https://github.com/openpeeps/boogie), which is experimental. Expect breaking changes. Steps are tagged, so grouped or auto-coalesced entries are traversed as a unit. `undo()` and `redo()` return the state at the new cursor position, except that JSON Patch steps surface their operations (backward on undo, forward on redo) so callers can transform their working document directly. Stepping before the first recorded entry moves the cursor onto the pristine state and returns `none`.

## Benchmarks

Release-mode numbers on the author's machine with small payloads (`clue build tests/t_benchmarks.nim --release:true`):

| Operation | Throughput |
|---|---|
| push snapshot (in-memory) | ~830 K ops/s |
| push diff (in-memory) | ~770 K ops/s |
| push json state (in-memory) | ~550 K ops/s |
| push jsonDiff delta (in-memory) | ~300 K ops/s |
| push snapshot (disk + WAL) | ~140 K ops/s |
| undo step (in-memory) | ~780 K steps/s |
| redo step (in-memory) | ~840 K steps/s |
| divergent push after undo (5K-entry rotation) | ~370 ops/s |
| compact() of a 10K-entry history | ~27/s |

The divergent-push figure reflects generation rotation copying the live prefix (O(history) per divergence). It is the cost of correct truncation semantics on an append-only store; keep bursts long and undos shallow for editor-like workloads.

## Roadmap

- **JSON Patch extensions**: `move`, `copy`, `test` operations and LCS-based array diffing
- **Branching history**: tree-shaped futures instead of a single linear chain
- **Multi-document stores**: several histories sharing one WAL file
- **Thread-safe mode**: concurrent readers/writers once boogie's LogStore gains concurrency

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/undo/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/undo/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
