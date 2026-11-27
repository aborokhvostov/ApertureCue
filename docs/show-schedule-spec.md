# Show Schedule

Open **Show → Schedule…**. Each event references one saved scene.
**Add event…** accepts a name, local start, time zone, scene and an optional repeat
rule. **Edit event…** and **Delete event** work on the selected row. These changes
are document edits and support Undo and Redo. Saving the project preserves the
calendar entries together with their scene references.

Enter the local start in `YYYYMMDDTHHMMSS` form and use an installed time-zone
identifier such as `Europe/Moscow`. Leave the repeat rule blank for one event.
`FREQ=DAILY` repeats at the same local time each day.
`FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR` repeats on Monday and Friday every other week.
Start on a listed weekday when using `BYDAY`. A rule can end at `COUNT=8` or at
an inclusive UTC bound such as `UNTIL=20271231T120000Z`.

Choose **Arm schedule** when the open project is ready to run. Its calendar can
recall a scene while the timeline is stopped. **Disarm schedule** ends automatic
recalls. New and Open start with the schedule disarmed. Pass `--arm-schedule`
when launching the app executable with a project path to arm that opened project
for the current process. The app uses its own calendar settings and the operating
system's installed time-zone rules.

## What happens when a start is due

- A poll considers start times crossed since the previous poll or arm action,
  up to and including its current wall time. It accepts starts at most
  30 seconds old. Starting the app, arming and editing the calendar establish a
  fresh crossing boundary at the current wall time.
- A delayed poll can cover several start times. The newest start wins. If starts
  share the same time, the first listed event wins. A conflict emits one scene
  recall through the normal cue engine.
- A backward wall-clock adjustment holds the previous high-water instant until
  wall time advances past it. The session also retains that instant through
  manual Disarm and Arm. Reopening starts a clean, disarmed session.
- A repeated local hour uses the first matching instant. The editor rejects a
  newly entered event that starts inside a skipped local hour. If an existing
  repeat rule reaches a skipped local start, the rule skips that occurrence
  before counting.

## Local ICS import

**Import ICS…** asks which scene each event should recall and which time zone
should interpret floating times. Choose one local UTF-8 iCalendar 2.0 file. Import
is an atomic document edit. The app keeps the event name, UID, supported timing
and selected scene. Descriptions, attendees, event end, alarms and other
annotations stay in the original file. Duplicate UIDs abort the import.

The supported subset is `VEVENT` with `UID` and a date-time `DTSTART`. Choose
`Z`, an installed `TZID` or an explicit floating zone. `RRULE` supports `DAILY`,
`WEEKLY`, `INTERVAL` 1–52, optional `COUNT` 1–512 or UTC `UNTIL` and weekly
`BYDAY` with Monday week starts. `EXDATE` excludes up to 256 converted instants
per event. This limit applies after duplicate exclusions are combined. `COUNT`
counts valid starts before exclusions. Events can be confirmed or omit status.

The importer rejects all-day events, custom `VTIMEZONE`, recurrence overrides,
additional inclusion rules, other recurrence fields and scheduling mail methods.
Supported local years are 1970–2199. The calendar accepts up to 128 entries and
a 256 KiB file. Import reads the selected local file. Calendar feeds and system
calendar accounts are outside this import path.

The subset uses the date-time, folding and recurrence conventions in
[RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html).
