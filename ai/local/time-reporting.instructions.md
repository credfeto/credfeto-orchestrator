# Time Reporting

[Back to Local Instructions Index](index.md)

* Every clock time reported to a human (chat, issue or PR comment, `ScheduleWakeup` reasons) MUST be in the local system time zone and carry its zone abbreviation, for example `17:05 BST`.
* Produce reported times with `date +%H:%M\ %Z`. NEVER use `date -u` or any other UTC-only source for a time that will be reported.
* NEVER mix UTC and local times in the same report.
* UTC remains fine where a machine compares timestamps (for example GitHub API `createdAt` values compared as text), because those are never shown to a human as clock times.
* The `timeZone` setting in `settings.json` and `env.TZ` cannot override an explicit `date -u`; the rule depends on the agent choosing local time.
