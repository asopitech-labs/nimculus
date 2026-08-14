import std/options

type
  EntityId* = distinct uint64

  Entity*[T] = object
    id*: EntityId
    generation*: uint32

  WeakEntity*[T] = object
    id*: EntityId
    generation*: uint32

  EntitySlot* = object
    gen*: uint32
    leased*: bool
    data*: RootRef

  EntityMap* = object
    slots*: seq[EntitySlot]
    free*: seq[int]

  EntityData[T] = ref object of RootObj
    value: T

proc `==`*(left, right: EntityId): bool = uint64(left) == uint64(right)

proc newEntityMap*(): EntityMap =
  EntityMap(slots: @[], free: @[])

proc slotIndex(id: EntityId): int =
  let raw = uint64(id)
  if raw == 0 or raw > uint64(high(int)): -1 else: int(raw - 1)

proc validSlot[T](map: EntityMap, entity: Entity[T]): int =
  let index = slotIndex(entity.id)
  if index < 0 or index >= map.slots.len:
    return -1
  let slot = map.slots[index]
  if slot.gen != entity.generation or slot.data == nil:
    return -1
  index

proc reservedSlot[T](map: EntityMap, entity: Entity[T]): int =
  let index = slotIndex(entity.id)
  if index < 0 or index >= map.slots.len:
    return -1
  let slot = map.slots[index]
  if slot.gen != entity.generation or slot.data != nil:
    return -1
  index

proc reserve*[T](map: var EntityMap): Entity[T] =
  var index: int
  if map.free.len > 0:
    index = map.free.pop()
    inc map.slots[index].gen
  else:
    index = map.slots.len
    map.slots.add(EntitySlot(gen: 1))
  Entity[T](id: EntityId(uint64(index + 1)),
            generation: map.slots[index].gen)

proc insert*[T](map: var EntityMap, entity: Entity[T], value: T): Entity[T] =
  let index = map.reservedSlot(entity)
  if index < 0:
    raise newException(ValueError, "cannot insert an invalid or already inserted entity")
  map.slots[index].data = EntityData[T](value: value)
  entity

proc reserve*[T](map: var EntityMap, value: T): Entity[T] =
  result = reserve[T](map)
  discard map.insert(result, value)

proc weak*[T](entity: Entity[T]): WeakEntity[T] =
  WeakEntity[T](id: entity.id, generation: entity.generation)

proc downgrade*[T](entity: Entity[T]): WeakEntity[T] = entity.weak()

proc upgrade*[T](weak: WeakEntity[T], map: EntityMap): Option[Entity[T]] =
  let entity = Entity[T](id: weak.id, generation: weak.generation)
  if map.validSlot(entity) >= 0: some(entity) else: none(Entity[T])

proc upgrade*[T](map: EntityMap, weak: WeakEntity[T]): Option[Entity[T]] =
  weak.upgrade(map)

proc isValid*[T](map: EntityMap, entity: Entity[T]): bool =
  map.validSlot(entity) >= 0

proc release*[T](map: var EntityMap, entity: Entity[T]): bool =
  let index = map.validSlot(entity)
  if index < 0:
    return false
  if map.slots[index].leased:
    raise newException(Defect, "cannot release a leased entity")
  map.slots[index].data = nil
  map.free.add(index)
  true

proc remove*[T](map: var EntityMap, entity: Entity[T]): bool =
  map.release(entity)

proc lease*[T](map: var EntityMap, entity: Entity[T]): var T =
  let index = map.validSlot(entity)
  if index < 0:
    raise newException(KeyError, "entity is not present")
  if map.slots[index].leased:
    raise newException(Defect, "double lease of entity")
  map.slots[index].leased = true
  result = cast[EntityData[T]](map.slots[index].data).value

proc endLease*[T](map: var EntityMap, entity: Entity[T]) =
  let index = slotIndex(entity.id)
  if index < 0 or index >= map.slots.len or
      map.slots[index].gen != entity.generation:
    raise newException(KeyError, "entity is not present")
  if not map.slots[index].leased:
    raise newException(Defect, "entity is not leased")
  map.slots[index].leased = false

proc read*[T](map: EntityMap, entity: Entity[T]): T =
  let index = map.validSlot(entity)
  if index < 0:
    raise newException(KeyError, "entity is not present")
  if map.slots[index].leased:
    raise newException(Defect, "double lease: cannot read a leased entity")
  result = cast[EntityData[T]](map.slots[index].data).value

proc read*[T, R](map: EntityMap, entity: Entity[T], callback: proc(value: T): R {.closure.}): R =
  let value = map.read(entity)
  callback(value)

proc update*[T, R](map: var EntityMap, entity: Entity[T],
                   callback: proc(value: var T): R {.closure.}): R =
  let index = map.validSlot(entity)
  if index < 0:
    raise newException(KeyError, "entity is not present")
  if map.slots[index].leased:
    raise newException(Defect, "double lease of entity")
  map.slots[index].leased = true
  try:
    result = callback(cast[EntityData[T]](map.slots[index].data).value)
  finally:
    map.endLease(entity)
