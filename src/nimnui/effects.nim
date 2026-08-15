## Application effects are queued until the outermost update finishes.

import std/[deques, hashes, sets, tables]
import nimnui/entity
import nimnui/entity_context except Effect, EffectKind

export entity_context except Effect, EffectKind
export deques, sets

type
  EffectKind* = enum
    efNotify
    efEmit
    efRefreshWindows
    efNotifyGlobalObservers
    efDefer
    efEntityCreated

  Effect* = object
    entityId*: EntityId
    case kind*: EffectKind
    of efNotify, efEmit, efRefreshWindows, efNotifyGlobalObservers, efEntityCreated:
      discard
    of efDefer:
      callback*: proc() {.closure.}

  EffectObserver = proc() {.closure.}

  EffectState = ref object
    pendingEffects: Deque[Effect]
    pendingNotifications: HashSet[EntityId]
    pendingUpdates: int
    flushingEffects: bool
    observers: Table[EntityId, seq[EffectObserver]]

var effectStates {.global.}: Table[pointer, EffectState]

proc newEffectState(): EffectState =
  EffectState(
    pendingEffects: initDeque[Effect](),
    pendingNotifications: initHashSet[EntityId](),
    pendingUpdates: 0,
    flushingEffects: false,
    observers: initTable[EntityId, seq[EffectObserver]]())

proc effectState(app: var App): EffectState =
  let key = cast[pointer](addr app)
  if not effectStates.hasKey(key):
    effectStates[key] = newEffectState()
  effectStates[key]

template pendingEffects*(app: var App): untyped =
  effectState(app).pendingEffects

template pendingNotifications*(app: var App): untyped =
  effectState(app).pendingNotifications

template pendingUpdates*(app: var App): untyped =
  effectState(app).pendingUpdates

template flushingEffects*(app: var App): untyped =
  effectState(app).flushingEffects

proc flushEffects*(app: var App)

proc startUpdate*(app: var App) =
  inc app.pendingUpdates

proc finishUpdate*(app: var App) =
  if app.pendingUpdates <= 0:
    raise newException(Defect, "finishUpdate called without a matching startUpdate")
  if app.pendingUpdates == 1 and not app.flushingEffects:
    app.flushEffects()
  dec app.pendingUpdates

proc pushEffect*(app: var App, effect: Effect) =
  case effect.kind
  of efNotify:
    if effect.entityId notin app.pendingNotifications:
      app.pendingNotifications.incl(effect.entityId)
      app.pendingEffects.addLast(effect)
  of efEmit, efRefreshWindows, efNotifyGlobalObservers, efDefer, efEntityCreated:
    app.pendingEffects.addLast(effect)

proc notify*(app: var App, entityId: EntityId) =
  app.pushEffect(Effect(kind: efNotify, entityId: entityId))

proc notify*[T](app: var App, entity: Entity[T]) =
  app.notify(entity.id)

proc observe*(app: var App, entityId: EntityId, callback: proc() {.closure.}) =
  app.effectState().observers.mgetOrPut(entityId, @[]).add(callback)

proc observe*[T](app: var App, entity: Entity[T], callback: proc() {.closure.}) =
  app.observe(entity.id, callback)

proc addObserver*(app: var App, entityId: EntityId, callback: proc() {.closure.}) =
  app.observe(entityId, callback)

proc dispatchNotify(app: var App, entityId: EntityId) =
  if not app.effectState().observers.hasKey(entityId):
    return
  let callbacks = app.effectState().observers[entityId]
  for callback in callbacks:
    callback()

proc dispatchEffect(app: var App, effect: Effect) =
  case effect.kind
  of efNotify:
    app.pendingNotifications.excl(effect.entityId)
    app.dispatchNotify(effect.entityId)
  of efEmit, efRefreshWindows, efNotifyGlobalObservers, efEntityCreated:
    discard
  of efDefer:
    if effect.callback != nil:
      effect.callback()

proc flushEffects*(app: var App) =
  if app.flushingEffects:
    return
  app.flushingEffects = true
  try:
    while app.pendingEffects.len > 0:
      let effect = app.pendingEffects.popFirst()
      app.dispatchEffect(effect)
  finally:
    app.flushingEffects = false
    app.pendingNotifications.clear()

template update*(app: var App, body: untyped): untyped =
  block:
    app.startUpdate()
    try:
      body
    finally:
      app.finishUpdate()

proc deferEffect*(callback: proc() {.closure.}): Effect =
  Effect(kind: efDefer, callback: callback)
