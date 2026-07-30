## Adaptive scheduling for event-loop services that need a polling fallback.

type
  PollSchedule* = object
    nextIdlePollAt*: float

proc reset*(schedule: var PollSchedule) =
  schedule = PollSchedule()

proc shouldPoll*(schedule: var PollSchedule, now: float, active: bool,
    idleInterval = 0.5): bool =
  ## Keep active incremental jobs responsive.  When no job is active, poll
  ## filesystem fallback work only at a bounded idle cadence.
  if active: return true
  if now < schedule.nextIdlePollAt: return false
  schedule.nextIdlePollAt = now + max(0.0, idleInterval)
  true
