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
- Open Source | `MIT` License
- Written in Nim language
- Three entry kinds: snapshots, diffs, and JSON document states
- Persistent by default (WAL-backed), with an in-memory mode for testing
- Operation grouping for batching multiple pushes into one undo step
- Linear cursor model: `canUndo` / `canRedo` / `undo` / `redo`
- Typed convenience accessors: `undoText` and `undoJson`

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

Batch several pushes into a single undoable step, like collapsing a burst of keystrokes into one undo action:

```nim
h.beginGroup()
h.pushDiff(0, 0, "a")
h.pushDiff(1, 0, "b")
h.pushDiff(2, 0, "c")
h.endGroup()
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
| `newHistoryManager(path, historyId)` | Opens or creates a disk-backed history |
| `newInMemoryHistoryManager(historyId)` | Creates an ephemeral in-memory history |
| `pushSnapshot(content)` | Records a full text snapshot |
| `pushDiff(offset, deletedLen, inserted)` | Records a text diff |
| `pushJson(data)` | Records a full JSON state |
| `beginGroup` / `endGroup` | Batches pushes into one step |
| `undo(): Option[HistoryContent]` | Steps back, returns the previous state |
| `redo(): Option[HistoryContent]` | Steps forward, returns the next state |
| `undoText(): Option[string]` | Undo typed as a snapshot string |
| `undoJson(): Option[JsonNode]` | Undo typed as a JSON node |
| `canUndo(): bool` / `canRedo(): bool` | Cursor availability checks |
| `close()` | Flushes and closes the underlying store |

> [!NOTE]
> `undo` is built on [boogie](https://github.com/openpeeps/boogie), which is experimental. Expect breaking changes. Both `undo()` and `redo()` return the state at the new cursor position; stepping before the first recorded entry returns `none`.

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/undo/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/undo/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
