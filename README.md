# besir — any input, one plan

An iOS planning agent that turns screenshots, Instagram posts and camera snaps into schedules, departure alarms and meal plans, powered by Meta Muse Spark.

## Pre-existing code (before the hackathon kickoff — Oct 26, 2026, 12:00 PM ET)

Everything in the baseline commit was written before the hackathon. It is tagged
[`pre-hackathon-baseline`](https://github.com/paul8004-lee/besir_global/tree/pre-hackathon-baseline).

What the baseline already does:

- **Calendar** — month grid, week strip and day timetable; long-press a block in the timetable to drag it to a new time
- **Manual entry** — add and edit trips and activities by hand, through one shared edit card that shows every value before saving
- **Recurrence rules** — weekly, every N weeks, daily, monthly (nth weekday), yearly, lunar and date-list repeats, with optional skipping of Korean public holidays
- **Favorites** — saved places such as home and work
- **Place search, travel time and route map** — place search and per-mode travel time (car, transit, walk, bicycle) through Kakao, with a MapKit search fallback and a native route map; the Kakao part is replaced during the hackathon
- **be full sir** — find a place to eat near a chosen location, log what was eaten, and turn a pick into a meal block with round-trip travel
- **Service home** — the start screen that switches between be on-time sir and be full sir
- **Settings**
- **Schedule model and `Store`** — events, activities and favorites held in a single store with on-device persistence
- **Departure-time calculation** — departure = arrival − travel time − buffer
- **Local notifications** — departure alarms scheduled from that calculation
- **Share extension skeleton** — receives shared text and images and hands them to the app through a shared inbox
- **Theme** — color tokens and the app mark, with light and dark mode following the device setting

The AI layer, calendar sync and map view of the earlier app were removed from the baseline; their replacements are built during the hackathon.

One commit sits between the baseline tag and the first hackathon work: [`89c8ab3`](https://github.com/paul8004-lee/besir_global/commit/89c8ab3d7e495ebb5f6e24724ffea86857bd2378), a one-line `.gitignore` tidy-up made before the kickoff (Oct 26, 2026, 07:40 AM ET).

## Built during the hackathon (Oct 26 – Nov 4, 2026)

Everything that differs from the baseline: [`pre-hackathon-baseline...main`](https://github.com/paul8004-lee/besir_global/compare/pre-hackathon-baseline...main).

Each merged unit of work gets one line below, in the form "what was newly built — link to its commit".

- _Nothing merged yet._

Some baseline files are edited in place, only for two reasons: the English localization of the app UI, and the split of the app and App Group identifiers from the earlier app. Both are listed as lines above when they land. Baseline files are never mass-reformatted, renamed or moved, so the diff shows old code and new code apart.

## Roadmap (not built yet)

- **be healthy sir** — fit workouts into the free time between plans
- **be fun sir** — suggest leisure and events that fit the day's schedule
- **be rich sir** — track spending tied to each plan
- **External integrations** — Apple Health, Ticketmaster, Plaid, and others
