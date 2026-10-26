# besir — any input, one plan

An iOS planning agent that turns screenshots, Instagram posts and camera snaps into schedules, departure alarms and meal plans, powered by Meta Muse Spark.

## Pre-existing code (before Oct 26, 2026)

Everything in the baseline commit was written before the hackathon. It is tagged
[`pre-hackathon-baseline`](https://github.com/<owner>/besir_global/tree/pre-hackathon-baseline) <!-- TODO: replace <owner> after the repository is published -->.

- **SwiftUI app shell** — app entry point, root navigation, settings screen
- **Schedule model and `Store`** — events, activities and favorites held in a single store with on-device persistence
- **Departure-time calculation** — departure = arrival − travel time − buffer
- **Local notifications** — departure alarms scheduled from that calculation
- **Share extension skeleton** — receives shared content and hands it to the app through a shared inbox
- **Theme** — color tokens and the app mark, with light and dark mode following the device setting

The AI layer, calendar sync and map view of the earlier app were removed from the baseline; their replacements are built during the hackathon.

## Built during the hackathon (Oct 26 – Nov 4, 2026)

TBD

## Roadmap (not built yet)

- **be healthy sir** — fit workouts into the free time between plans
- **be fun sir** — suggest leisure and events that fit the day's schedule
- **be rich sir** — track spending tied to each plan
- **External integrations** — Apple Health, Ticketmaster, Plaid, and others
