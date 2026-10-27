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

- **Muse Spark proxy** — a new Cloudflare Worker, `besir-global-proxy`, that forwards `/ai` requests to Meta Muse Spark (`muse-spark-1.3`) with responses never stored by the provider, and relays `/places` and `/routes` for Google; keys live only in Worker secrets — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Own app identity and a working build** — new bundle IDs (`com.iseongmin.besir.global`, `.global.share`) and App Group, so the app installs next to the earlier one; the iOS build is restored by removing every reference to the code that was trimmed from the baseline (assistant layer, cloud sync and account, Kakao map) — [`4b84722`](https://github.com/paul8004-lee/besir_global/commit/4b84722405c861823865bf762500ef6a9aa24f4a)
- **English app screens and dates** — the app now runs in the `en_US` locale: screen labels, buttons, alerts, notification text and date/time formats (for example `October 2026`, `Tue, Oct 27, 3:05 PM`) are English, with 375 strings translated and the code structure unchanged; transit step names, recurrence summaries and the location permission prompt follow in later cards — [`9567b8c`](https://github.com/paul8004-lee/besir_global/commit/9567b8c3b50ed2022903e3c4e149a81f8efe8c40)
- **English location permission text** — the iOS location prompt now explains in English why the app asks for location ("besir uses your current location to calculate your departure time."); the plist matches what the project generator would write — [`b252ec1`](https://github.com/paul8004-lee/besir_global/commit/b252ec15aa033ef5b1f2638711b2d3c7f32108ec)
- **Worker deployment** — the proxy Worker is live on Cloudflare Workers with its app token and the Meta key held only as Worker secrets, and its first Muse Spark call succeeded on the deployed Worker; the deployed code is the Muse Spark proxy commit — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Approximate place name fix** — when the app falls back to an IP-based approximate location, a region and city with the same name (for example `Seoul Seoul`) are now shown once — [`8cce40d`](https://github.com/paul8004-lee/besir_global/commit/8cce40d93d59040a6757566bfb6098d4bd3e1806)
- **Google key on the Worker** — the proxy Worker now holds the Google key as a Worker secret, and both Places and Routes were called live once through it; the app is not wired to it yet — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Worker placement near US East** — the proxy Worker now runs next to US East (`[placement] region = "aws:us-east-1"`), after model API calls leaving Cloudflare in Hong Kong or Tokyo were answered `model_not_found` while the same call sent directly succeeded — [`702c90b`](https://github.com/paul8004-lee/besir_global/commit/702c90ba7c176926cb908482d64946f8e30596bc)
- **Muse Spark schedule agent** — a chat sheet opened from the besir logo on every screen talks to Muse Spark through the Worker; the model looks up, creates, changes and deletes events through app tools, every change waits for the user to tap Confirm on an in-chat card, and the app checks and cleans every tool argument the model sends; adds the app's first unit test target (105 tests) — [`9853f8c`](https://github.com/paul8004-lee/besir_global/commit/9853f8c40b8a549f1dba92a94f57159fda7ed956)
- **Agent audit repairs** — backups such as `Config/Local.xcconfig.bak` are now ignored by git, Settings no longer writes the bundled Worker host and token into `config.json`, stored event titles and place names are cleaned before they reach agent cards and lists, the agent reads the current time zone on every use instead of fixing it when the chat first opens, and a create card re-checks its start time at Confirm; 7 new unit tests (112 in total) — [`e48a473`](https://github.com/paul8004-lee/besir_global/commit/e48a4737ea2d3187f775de8f2722645cf50a3672)
- **Image reading route** — the proxy Worker has a new `/vision` route that sends one image to Muse Spark Open and returns only a title, a time, a place and a confidence; the model key is held only as a Worker secret, and one real call with a synthetic poster came back with all three fields read correctly; accuracy on other images and on large images is not proven, and the app is not wired to it yet — [`78642ec`](https://github.com/paul8004-lee/besir_global/commit/78642ec814e9952a27b5832a04616d18a8ebc666)

Some baseline files are edited in place, only for two reasons: the English localization of the app UI, and the split of the app and App Group identifiers from the earlier app. Both are listed as lines above when they land. Baseline files are never mass-reformatted, renamed or moved, so the diff shows old code and new code apart.

## Roadmap (not built yet)

- **be healthy sir** — fit workouts into the free time between plans
- **be fun sir** — suggest leisure and events that fit the day's schedule
- **be rich sir** — track spending tied to each plan
- **External integrations** — Apple Health, Ticketmaster, Plaid, and others
