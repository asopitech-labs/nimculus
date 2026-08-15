## Entity-scoped access to the application store.
##
## `context.nim` is intentionally kept for keymap contexts.  This module is
## the NimNUI counterpart of gpui's `Context<T>` and therefore uses the less
## ambiguous `EntityContext<T>` name.

import std/asyncfutures
import nimnui/entity
import nimnui/executor

export entity, executor

type
  EffectKind* = enum
    notifyEffect
    emitEffect

  EventBoxBase = ref object of RootObj

  EventBox[E] = ref object of EventBoxBase
    value: E

  Effect* = object
    kind*: EffectKind
    emitter*: EntityId
    generation*: uint32
    event: EventBoxBase

  Subscription* = object
    id*: uint64

  ObserverCallback = proc(app: var App, entityId: EntityId) {.closure.}
  EventDelivery = proc(app: var App, event: EventBoxBase) {.closure.}
  ReleaseCallback = proc(app: var App, entityId: EntityId) {.closure.}

  Observer = object
    subscription: Subscription
    target: WeakEntity[RootRef]
    callback: ObserverCallback

  Subscriber = object
    subscription: Subscription
    emitter: WeakEntity[RootRef]
    delivery: EventDelivery

  ReleaseObserver = object
    subscription: Subscription
    target: WeakEntity[RootRef]
    callback: ReleaseCallback

  SpawnJob = ref object
    target: WeakEntity[RootRef]
    run: proc() {.closure.}

  App* = object
    ## The entity store is public so framework code can inspect it when it
    ## needs to perform a weak-handle upgrade. Mutation should normally use
    ## `update` and `release` below.
    entities*: EntityMap
    ## Effects waiting to be flushed. `effectHistory` is retained for cheap
    ## diagnostics and for tests that need to count queued effects after a
    ## complete update.
    effects*: seq[Effect]
    effectHistory*: seq[Effect]
    observers: seq[Observer]
    subscribers: seq[Subscriber]
    releaseObservers: seq[ReleaseObserver]
    pendingSpawns: seq[SpawnJob]
    nextSubscriptionId: uint64
    pendingUpdates: int
    flushingEffects: bool

  EntityContext*[T] = object
    app: ptr App
    entity: WeakEntity[T]

proc newApp*(): App =
  App(entities: newEntityMap(), effects: @[], effectHistory: @[],
      observers: @[], subscribers: @[], releaseObservers: @[],
      pendingSpawns: @[],
      nextSubscriptionId: 0, pendingUpdates: 0, flushingEffects: false)

proc entityId*[T](cx: EntityContext[T]): EntityId = cx.entity.id

proc entity*[T](cx: EntityContext[T]): Entity[T] =
  Entity[T](id: cx.entity.id, generation: cx.entity.generation)

proc weakEntity*[T](cx: EntityContext[T]): WeakEntity[T] = cx.entity

proc nextSubscription(app: var App): Subscription =
  inc app.nextSubscriptionId
  Subscription(id: app.nextSubscriptionId)

proc newEntity*[T](app: var App, value: T): Entity[T] =
  app.entities.reserve(value)

proc createEntity*[T](app: var App, value: T): Entity[T] =
  app.newEntity(value)

proc reserveEntity*[T](app: var App, value: T): Entity[T] =
  app.newEntity(value)

proc hasEffect*(app: App, kind: EffectKind, id: EntityId): bool =
  for effect in app.effects:
    if effect.kind == kind and effect.emitter == id:
      return true
  false

proc queueNotify(app: var App, id: EntityId, generation: uint32) =
  if app.hasEffect(notifyEffect, id): return
  app.effects.add(Effect(kind: notifyEffect, emitter: id,
                         generation: generation))

proc notify*[T](cx: var EntityContext[T]) =
  cx.app[].queueNotify(cx.entity.id, cx.entity.generation)

proc invokeObservers(app: var App, id: EntityId, generation: uint32) =
  var index = 0
  while index < app.observers.len:
    let observer = app.observers[index]
    if observer.target.id == id and observer.target.generation == generation:
      observer.callback(app, id)
    inc index

proc invokeSubscribers(app: var App, effect: Effect) =
  var index = 0
  while index < app.subscribers.len:
    let subscriber = app.subscribers[index]
    if subscriber.emitter.id == effect.emitter and
        subscriber.emitter.generation == effect.generation:
      subscriber.delivery(app, effect.event)
    inc index

proc flushEffects*(app: var App) =
  if app.flushingEffects: return
  app.flushingEffects = true
  try:
    while app.effects.len > 0:
      let effect = app.effects[0]
      app.effects.delete(0)
      app.effectHistory.add(effect)
      case effect.kind
      of notifyEffect:
        app.invokeObservers(effect.emitter, effect.generation)
      of emitEffect:
        app.invokeSubscribers(effect)
  finally:
    app.flushingEffects = false

proc updateEntity[T, C](app: var App, entity: Entity[T], body: C) =
  inc app.pendingUpdates
  var cx = EntityContext[T](app: addr app, entity: entity.weak())
  var state = app.entities.lease(entity)
  try:
    body(state, cx)
  finally:
    app.entities.endLease(entity)
    dec app.pendingUpdates
    if app.pendingUpdates == 0:
      app.flushEffects()

template update*[T](app: var App, entity: Entity[T], body: untyped): untyped =
  updateEntity(app, entity, body)

proc release*[T](app: var App, entity: Entity[T]): bool =
  result = app.entities.release(entity)
  if not result: return
  var index = 0
  while index < app.releaseObservers.len:
    let observer = app.releaseObservers[index]
    if observer.target.id == entity.id and
        observer.target.generation == entity.generation:
      observer.callback(app, entity.id)
    inc index
  index = 0
  while index < app.pendingSpawns.len:
    let job = app.pendingSpawns[index]
    if job.target.id == entity.id and job.target.generation == entity.generation:
      app.pendingSpawns.delete(index)
      job.run()
    else:
      inc index

proc observe*[T, U](cx: var EntityContext[T], target: Entity[U],
                    callback: proc() {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let targetWeak = target.weak()
  cx.app[].observers.add(Observer(
    subscription: result,
    target: WeakEntity[RootRef](id: targetWeak.id, generation: targetWeak.generation),
    callback: proc(app: var App, entityId: EntityId) =
    discard (app, entityId)
    callback()))

proc observe*[T, U](cx: var EntityContext[T], target: Entity[U],
                    callback: proc(app: var App, entity: Entity[U]) {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let targetWeak = target.weak()
  cx.app[].observers.add(Observer(
    subscription: result,
    target: WeakEntity[RootRef](id: targetWeak.id, generation: targetWeak.generation),
    callback: proc(app: var App, entityId: EntityId) =
    callback(app, Entity[U](id: entityId, generation: targetWeak.generation))))

proc subscribe*[T, U, E](cx: var EntityContext[T], emitter: Entity[U],
                         callback: proc(event: E) {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let emitterWeak = emitter.weak()
  cx.app[].subscribers.add(Subscriber(
    subscription: result,
    emitter: WeakEntity[RootRef](id: emitterWeak.id, generation: emitterWeak.generation),
    delivery: proc(app: var App, event: EventBoxBase) =
    discard app
    callback(cast[EventBox[E]](event).value)))

proc subscribe*[T, U, E](cx: var EntityContext[T], emitter: Entity[U],
                         callback: proc(app: var App, event: E) {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let emitterWeak = emitter.weak()
  cx.app[].subscribers.add(Subscriber(
    subscription: result,
    emitter: WeakEntity[RootRef](id: emitterWeak.id, generation: emitterWeak.generation),
    delivery: proc(app: var App, event: EventBoxBase) =
    callback(app, cast[EventBox[E]](event).value)))

proc emit*[T, E](cx: var EntityContext[T], event: E) =
  cx.app[].effects.add(Effect(kind: emitEffect, emitter: cx.entity.id,
                              generation: cx.entity.generation,
                              event: EventBox[E](value: event)))

proc onRelease*[T](cx: var EntityContext[T], callback: proc() {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let target = cx.entity
  cx.app[].releaseObservers.add(ReleaseObserver(
    subscription: result,
    target: WeakEntity[RootRef](id: target.id, generation: target.generation),
    callback: proc(app: var App, entityId: EntityId) =
    discard (app, entityId)
    callback()))

proc onRelease*[T](cx: var EntityContext[T], callback: proc(
    app: var App) {.closure.}): Subscription =
  result = cx.app[].nextSubscription()
  let target = cx.entity
  cx.app[].releaseObservers.add(ReleaseObserver(
    subscription: result,
    target: WeakEntity[RootRef](id: target.id, generation: target.generation),
    callback: proc(app: var App, entityId: EntityId) =
    discard entityId
    callback(app)))

proc unsubscribe*(app: var App, subscription: Subscription) =
  var index = 0
  while index < app.observers.len:
    if app.observers[index].subscription.id == subscription.id:
      app.observers.delete(index)
    else:
      inc index
  index = 0
  while index < app.subscribers.len:
    if app.subscribers[index].subscription.id == subscription.id:
      app.subscribers.delete(index)
    else:
      inc index
  index = 0
  while index < app.releaseObservers.len:
    if app.releaseObservers[index].subscription.id == subscription.id:
      app.releaseObservers.delete(index)
    else:
      inc index

proc spawn*[T, R](cx: var EntityContext[T],
                  work: proc(entity: WeakEntity[T]): R {.closure.}): Task[R] =
  ## The job retains only a weak handle. The App releases it when the owning
  ## entity is released, so the work can safely observe that the slot is gone.
  ## `flushSpawnTasks` is also available for executors that want to run jobs
  ## for entities that remain alive.
  let future = newFuture[R]("EntityContext.spawn")
  let weak = cx.weakEntity()
  let callback = proc() =
    try:
      future.complete(work(weak))
    except CatchableError:
      future.fail(cast[ref CatchableError](getCurrentException()))
  cx.app[].pendingSpawns.add(SpawnJob(
    target: WeakEntity[RootRef](id: weak.id, generation: weak.generation),
    run: callback))
  future

proc flushSpawnTasks*(app: var App) =
  while app.pendingSpawns.len > 0:
    let job = app.pendingSpawns[0]
    app.pendingSpawns.delete(0)
    job.run()

proc pendingEffectCount*(app: App): int = app.effects.len

proc notifyEffectCount*(app: App, id: EntityId): int =
  for effect in app.effectHistory:
    if effect.kind == notifyEffect and effect.emitter == id:
      inc result

template entityMap*[T](cx: EntityContext[T]): untyped = cx.app[].entities
template pendingEffects*[T](cx: EntityContext[T]): untyped = cx.app[].effects
template release*[T, U](cx: EntityContext[T], target: Entity[U]): untyped =
  cx.app[].release(target)
template flushEffects*[T](cx: var EntityContext[T]): untyped =
  cx.app[].flushEffects()
template pendingEffectCount*[T](cx: EntityContext[T]): untyped =
  cx.app[].pendingEffectCount()
template flushSpawnTasks*[T](cx: var EntityContext[T]): untyped =
  cx.app[].flushSpawnTasks()
