## Bounded trailing-edge scheduling for durable editor-session writes.
##
## The scheduler is intentionally independent from the event loop so each
## platform can poll it without turning every idle callback into disk I/O.

type
  PersistenceSchedule* = object
    pending*: bool
    startedAt*: float
    dueAt*: float

const
  WorkspaceCompositionPersistenceDelay* = 0.2
  TextEditPersistenceTrailingDelay* = 1.0
  TextEditPersistenceMaximumDelay* = 5.0

proc clear*(schedule: var PersistenceSchedule) =
  schedule = PersistenceSchedule()

proc schedule*(schedule: var PersistenceSchedule, now: float,
    trailingDelay = TextEditPersistenceTrailingDelay,
    maximumDelay = TextEditPersistenceMaximumDelay) =
  ## Move the trailing deadline for a new edit, without postponing recovery
  ## forever when input is continuous.
  if not schedule.pending:
    schedule.pending = true
    schedule.startedAt = now
  schedule.dueAt = min(now + trailingDelay, schedule.startedAt + maximumDelay)

proc isDue*(schedule: PersistenceSchedule, now: float): bool =
  schedule.pending and now >= schedule.dueAt
