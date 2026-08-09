import std/times

proc plural(value: int; singular, pluralForm: string): string =
  if value == 1: $value & " " & singular
  else: $value & " " & pluralForm

proc formatCompoundYearMonth(months: int): string =
  let years = months div 12
  let remainingMonths = months mod 12
  if remainingMonths == 0:
    return plural(years, "year", "years") & " ago"
  plural(years, "year", "years") & ", " &
    plural(remainingMonths, "month", "months") & " ago"

proc daysBeforeYear(year: int): int64 =
  let y = year - 1
  int64(365 * y + y div 4 - y div 100 + y div 400)

proc dayOrdinal(year, month, day: int): int64 =
  let monthOffsets = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  let leapDay = if month > 2 and (year mod 4 == 0 and
      (year mod 100 != 0 or year mod 400 == 0)): 1 else: 0
  daysBeforeYear(year) + int64(monthOffsets[month - 1] + leapDay + day)

proc formatRelativeDate*(timestamp, now: int64): string =
  let currentDate = fromUnix(now).local
  let timestampDate = fromUnix(timestamp).local
  let days = int(dayOrdinal(currentDate.year, currentDate.month.int,
      currentDate.monthday) - dayOrdinal(timestampDate.year, timestampDate.month.int,
      timestampDate.monthday))
  if days <= 0: return "Today"
  if days == 1: return "Yesterday"
  if days < 7: return $days & " days ago"
  let weeks = days div 7
  if days <= 28 and weeks <= 4: return plural(weeks, "week", "weeks") & " ago"

  let months = (currentDate.year - timestampDate.year) * 12 +
    currentDate.month.int - timestampDate.month.int
  if months <= 1: return "1 month ago"
  if months < 12: return $months & " months ago"
  if months < 60: return formatCompoundYearMonth(months)
  let years = (months + 6) div 12
  plural(years, "year", "years") & " ago"

proc formatRelativeTime*(timestamp, now: int64): string =
  let elapsedSeconds = max(0'i64, now - timestamp)
  let minutes = int(elapsedSeconds div 60)
  if minutes == 0: return "Just now"
  if minutes == 1: return "1 minute ago"
  if minutes < 60: return $minutes & " minutes ago"
  let hours = minutes div 60
  if hours == 1: return "1 hour ago"
  if hours < 24: return $hours & " hours ago"

  formatRelativeDate(timestamp, now)

proc formatRelativeTime*(timestamp: int64): string =
  formatRelativeTime(timestamp, getTime().toUnix)
