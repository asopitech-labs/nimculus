import std/[options, unittest]
import nimnui/context
import nimnui/entity_context

type
  Counter = object
    value: int

  Signal = object
    value: int

proc registerSignalSubscriber(app: var App, emitter: Entity[Counter], expected: int,
                              deliveries, misdeliveries: ptr int) =
  let subscriber = app.newEntity(Counter())
  let fixedEmitter = emitter
  let fixedExpected = expected
  app.update(subscriber, proc(state: var Counter, cx: var EntityContext[Counter]) =
    discard state
    discard cx.subscribe(fixedEmitter, proc(event: Signal) =
      if event.value == fixedExpected: inc deliveries[] else: inc misdeliveries[]))

proc emitSignal(app: var App, emitter: Entity[Counter], value: int) =
  let fixedValue = value
  app.update(emitter, proc(state: var Counter, cx: var EntityContext[Counter]) =
    discard state
    cx.emit(Signal(value: fixedValue)))

suite "entity context":
  test "keymap Context and EntityContext names coexist":
    let keymapContext = keyContext("editor")
    check keymapContext.contains("editor")

  test "update carries the entity identity into its context":
    var app = newApp()
    var checked = 0
    var entities: seq[Entity[Counter]] = @[]
    for _ in 0 ..< 100:
      entities.add(app.newEntity(Counter()))
    for entity in entities:
      app.update(entity, proc(state: var Counter, cx: var EntityContext[Counter]) =
        discard state
        check cx.entity().id == entity.id
        inc checked)
    check checked == 100

  test "notify is scoped, queued once, and runs the observer once":
    var app = newApp()
    let observed = app.newEntity(Counter())
    let source = app.newEntity(Counter())
    let other = app.newEntity(Counter())
    var runs = 0
    app.update(source, proc(state: var Counter, cx: var EntityContext[Counter]) =
      discard state
      discard cx.observe(observed, proc() = inc runs))
    app.update(observed, proc(state: var Counter, cx: var EntityContext[Counter]) =
      discard state
      cx.notify()
      cx.notify()
      cx.notify())
    check app.notifyEffectCount(observed.id) == 1
    check runs == 1
    app.update(other, proc(state: var Counter, cx: var EntityContext[Counter]) =
      discard state
      cx.notify())
    check app.notifyEffectCount(other.id) == 1
    check runs == 1

  test "emit only reaches subscribers of the current emitter":
    var app = newApp()
    var emitters: seq[Entity[Counter]] = @[]
    for _ in 0 ..< 3:
      emitters.add(app.newEntity(Counter()))
    var deliveries = 0
    var misdeliveries = 0
    for emitterIndex, emitter in emitters:
      for _ in 0 ..< 5:
        registerSignalSubscriber(app, emitter, emitterIndex, addr deliveries,
          addr misdeliveries)
    for emitterIndex, emitter in emitters:
      emitSignal(app, emitter, emitterIndex)
    check deliveries == 15
    check misdeliveries == 0

  test "spawn passes a weak handle that observes release":
    var app = newApp()
    let entity = app.newEntity(Counter())
    var upgraded = 0
    var task: Task[bool]
    app.update(entity, proc(state: var Counter, cx: var EntityContext[Counter]) =
      discard state
      task = cx.spawn(proc(weak: WeakEntity[Counter]): bool =
        weak.upgrade(app.entities).isSome))
    check app.release(entity)
    pollAsyncDispatchTick()
    check task.finished
    check task.read == false
    if task.finished:
      inc upgraded
    check upgraded == 1
