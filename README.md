# besir — the app that connects your apps

An iOS planning agent, powered by Meta Muse Spark, that sits between the apps on your phone. What you find in one app becomes a plan, and the plan is carried to the next app for you.

## Why besir: connecting apps

Google connected websites. Facebook and Instagram connected people. **besir connects the apps on your phone.**

Today a plan is spread across apps: a festival you saw on Instagram, a restaurant you found on a map, a booking in a reservation app, the time in your calendar. You copy and paste between them yourself. besir is the layer in the middle: it reads what you share, turns it into a plan with Muse Spark, and hands each piece to the app that needs it, filled in so that you only check it and confirm.

Three principles guide every connection:

- **Convenience** — besir fills in the details (time, place, travel time, party size); the user's only job is to confirm.
- **Your apps stay your apps** — besir does not replace the apps you already use, so there is no new service to sign up for and no habit to give up. Instead it connects them, even apps from fields that seem to have nothing in common, so that the whole plan can be managed from one place.
- **The user stays in control** — nothing is saved or sent to another app until the user taps Confirm, and besir only receives what the user chooses to share (no scraping).

Not every app offers an API or MCP server for this, so besir carries data in one common shape — which app it came from, which app it goes to, what it is and its status — whatever the app on the other side supports.

As an MVP, besir starts with one everyday scenario — an event you came across, a place to eat nearby, a booking and the time in your calendar — and connects the few apps that scenario needs. Each app connected later adds to what the others can do, so the value of besir grows with every new connection. The table below shows where each connection stands today.

| Connection | Direction | Status |
|---|---|---|
| Instagram post or screenshot → besir, through the iOS share sheet | in | built for screenshots and photos; an Instagram post shares only its link, which besir does not open |
| Image → Muse Spark Open, read into a title, time and place | in | built |
| besir ↔ Google Places and Routes | both ways | built |
| Muse Spark agent → besir schedule, through tool calls the user confirms | in | built |
| besir → Apple Calendar | out | built for the events you confirm, written to the default calendar; reading today's events is built but only a Debug button uses it until Plan my day |
| besir → a reservation app, filled in from the plan, and the booking back into besir | round trip | built with a simulated partner app clearly labeled *Simulated*; no real reservation app yet |
| besir ↔ a budget app (this week's dining budget left, a spend, a booking's estimated spend) | round trip | built with a simulated partner app clearly labeled *Simulated*; no real budget app yet |
| besir → health apps | out | roadmap |

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

Each merged unit of work gets one short line below: what was newly built and a link to its commit. From card t62 on, the details of each card (scope, tests, walk results) are in its issue and pull request.

- **Muse Spark proxy** — a Cloudflare Worker that forwards `/ai` to Meta Muse Spark and relays `/places` and `/routes` to Google; keys live only in Worker secrets — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Own app identity and a working build** — new bundle IDs and App Group, and the iOS build restored after the baseline trim — [`4b84722`](https://github.com/paul8004-lee/besir_global/commit/4b84722405c861823865bf762500ef6a9aa24f4a)
- **English app screens and dates** — screen text and date formats in `en_US` (375 strings) — [`9567b8c`](https://github.com/paul8004-lee/besir_global/commit/9567b8c3b50ed2022903e3c4e149a81f8efe8c40)
- **English location permission text** — the iOS location prompt in English — [`b252ec1`](https://github.com/paul8004-lee/besir_global/commit/b252ec15aa033ef5b1f2638711b2d3c7f32108ec)
- **Worker deployment** — the proxy Worker live on Cloudflare with its secrets; the first Muse Spark call succeeded — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Approximate place name fix** — a region and city with the same name (`Seoul Seoul`) show once — [`8cce40d`](https://github.com/paul8004-lee/besir_global/commit/8cce40d93d59040a6757566bfb6098d4bd3e1806)
- **Google key on the Worker** — the Google key held as a Worker secret; Places and Routes called live once — [`fa5a918`](https://github.com/paul8004-lee/besir_global/commit/fa5a918b826e07db8ee1fe64c38257c7a9244afe)
- **Worker placement near US East** — the Worker runs next to `aws:us-east-1`, which ended the `model_not_found` answers — [`702c90b`](https://github.com/paul8004-lee/besir_global/commit/702c90ba7c176926cb908482d64946f8e30596bc)
- **Muse Spark schedule agent** — a chat sheet where Muse Spark looks up, creates, changes and deletes events through app tools, each change confirmed on a card; the first unit test target — [`9853f8c`](https://github.com/paul8004-lee/besir_global/commit/9853f8c40b8a549f1dba92a94f57159fda7ed956)
- **Agent audit repairs** — cleaned titles and place names for the agent, the current time zone on every use, the start time re-checked at Confirm — [`e48a473`](https://github.com/paul8004-lee/besir_global/commit/e48a4737ea2d3187f775de8f2722645cf50a3672)
- **Image reading route** — a Worker `/vision` route that reads one image into a title, a time and a place — [`78642ec`](https://github.com/paul8004-lee/besir_global/commit/78642ec814e9952a27b5832a04616d18a8ebc666)
- **Google place search** — every place search goes to Google Places through the Worker, with the Google Maps mark — [`5ed7598`](https://github.com/paul8004-lee/besir_global/commit/5ed7598699c8ef8460eb1115604b4370154f1f47)
- **Agent reply polish** — no preface bubbles, plain 12-hour replies, and a message field that grows to five lines — [`bfacd61`](https://github.com/paul8004-lee/besir_global/commit/bfacd6153c8dbfe4a00d47842ef54f2d121d6a2f)
- **Google travel times** — car, transit, walk and bicycle times from Google Routes, with English transit steps — [`2619c40`](https://github.com/paul8004-lee/besir_global/commit/2619c409cd3e165dca8d211a8aac984b534fd7e1)
- **Share to event** — a screenshot or photo shared to besir is read by Muse Spark and becomes an Add event card — [`46cf9d8`](https://github.com/paul8004-lee/besir_global/commit/46cf9d89b825337ae564a45d81a39b27e004f6e5)
- **Chat freeze fix** — a long message in a full chat no longer freezes the app — [`b4d52d5`](https://github.com/paul8004-lee/besir_global/commit/b4d52d5f978f2697cde60d2dc69ad31f6c7bab87)
- **Apple Calendar** — confirmed events are written to the default calendar through EventKit; besir edits and deletes only the events it wrote — [`40c9c00`](https://github.com/paul8004-lee/besir_global/commit/40c9c000ceef1a7c3fb854a62c7bf15ea293db91)
- **Connections log** — every connection (Google, image reading, the chat agent) is logged on the phone as one common packet, with no personal content — [`a92d77d`](https://github.com/paul8004-lee/besir_global/commit/a92d77d6bbfd90a64150535c079c14d4944ab358)
- **Starting point fix** — a real location fix replaces the IP-based guess as the trip origin — [`4a3b0e8`](https://github.com/paul8004-lee/besir_global/commit/4a3b0e82ae61ac60c27f1cf6df532ca541e4e973)
- **Places and travel times in the chat agent** — the agent searches places and looks up travel times, and an Add event card carries a leg verified by Routes — [`8a6468a`](https://github.com/paul8004-lee/besir_global/commit/8a6468a1bde375800caf52a93905ffac01d5e192)
- **Google map on the travel-leg screen** — the origin and the destination drawn on a Google map from the Maps SDK — [`2257058`](https://github.com/paul8004-lee/besir_global/commit/225705898f65c30ebf37b3c0332bdb24f02347e2)
- **Simulated table-booking round trip** — a `request_booking` tool and a `/booking` Worker route answered by a fictional partner, Example Tables — [`2c5133b`](https://github.com/paul8004-lee/besir_global/commit/2c5133bb10a803179c9ec1bdc44cb94ee9ea5670)
- **Short line for a shared item in the chat** — the chat shows a short line for a share instead of the data the model receives — [`c7328cc`](https://github.com/paul8004-lee/besir_global/commit/c7328cc37cc3353f53ad172fb9abda9e5c40fa48)
- **Connections log follow-up** — tool names only from besir's own tools, a `No route` status, and one-line rows — [`04c75e3`](https://github.com/paul8004-lee/besir_global/commit/04c75e3bf258d94e8f6fce4a48ec5023eba7abd8)
- **Live replan** — car trips re-checked with live traffic on app open and alert tap, with an earlier, later or late note and a drafted delay message — [`6b80655`](https://github.com/paul8004-lee/besir_global/commit/6b8065562e30cece5635c68028705b107fdc1dd2)
- **Location permission fix** — Current Location works on any grant, and an IP-based guess is never saved as an origin — [`5ffb931`](https://github.com/paul8004-lee/besir_global/commit/5ffb931c8f85816b7bdf609c450115be83157a02)
- **Share card without diagnostic lines** — the Debug share card shows diagnostic lines only when a share fails — [`6188ec3`](https://github.com/paul8004-lee/besir_global/commit/6188ec3fa645b77aac7985dc3e4a107e852d151e)
- **Connections tab removed** — Settings is back to General and Favorites; the connection log itself is unchanged — [`ca07b26`](https://github.com/paul8004-lee/besir_global/commit/ca07b26c111d66ec2a4de4f4f91b3b662d714ea3)
- **Live replan after the alert** — a later departure found after the alert shows `Leave by …` instead of the red warning — [`7712802`](https://github.com/paul8004-lee/besir_global/commit/771280258ece346619b9ea634b0250250d40e391)
- **Chat lookups in one connection flow** — Places and Routes records carry the flow id of the chat message that caused them — [`7087126`](https://github.com/paul8004-lee/besir_global/commit/708712673cefff938b68a6b4ac67ec392d5b8169)
- **Failed place search told apart from an empty one** — the agent says places are unavailable instead of "nothing found" — [`047239a`](https://github.com/paul8004-lee/besir_global/commit/047239a7f3b4241e93624910e8cbc3e032c8cca4)
- **be full sir and nearby-suggestion fixes** — no caption under the Home button, a nearby search when the base changes, suggestion titles by type, and the chosen place's own name in the Place field — [`0412e99`](https://github.com/paul8004-lee/besir_global/commit/0412e995152b4789552180543619dfa9d9be63c5)
- **Plan my day** — one tap sends the shared items and today's calendar to the agent, which proposes the stops on one card; the app checks overlaps and travel times with Google Routes — [`b474859`](https://github.com/paul8004-lee/besir_global/commit/b4748590292728fe4ad8befdbf063096eb6bdf28)
- **Repeat text read by rules** — common English repeat phrases such as `every Monday until Nov 30` become a repeat rule inside the app, with no AI call — [`7cf990d`](https://github.com/paul8004-lee/besir_global/commit/7cf990d5690776d851949353ee1f4da10459e376)
- **Brief README lines** — each line here is now a short index entry; card details move to issues and pull requests — [#5](https://github.com/paul8004-lee/besir_global/pull/5)
- **Issue and pull request templates** — one card template for issues and one for pull requests, so every card reads the same — [#8](https://github.com/paul8004-lee/besir_global/pull/8)
- **Calendar not read, said so** — when Plan my day cannot read the calendar, the agent is told so and says its plan was not compared with the calendar, instead of calling the day clear — [#10](https://github.com/paul8004-lee/besir_global/pull/10)
- **Route line on the Google map** — a travel leg's map now draws the real route from Google Routes between the two pins, for car, walk, bicycle and transit, in light and dark — [#27](https://github.com/paul8004-lee/besir_global/pull/27)
- **Camera snap** — one photo and the phone's location find the exact place; a food place becomes a meal in the free time, a poster or any other place becomes a plan, and the photo is not kept; the same photo-to-place flow can later take its photo from Meta AI glasses (roadmap, not built) — [#30](https://github.com/paul8004-lee/besir_global/pull/30)
- **Absurdly long legs are not late arrivals** — in Plan my day, a leg over six hours counts as unchecked instead of showing a huge late-arrival time — [#31](https://github.com/paul8004-lee/besir_global/pull/31)
- **Example Budget (Simulated)** — a simulated budget app: ask what is left this week, say what you spent, and a booking sends its estimated spend; facts only, no advice — [#36](https://github.com/paul8004-lee/besir_global/pull/36)
- **Share, then one tap** — after a share, one fixed notification brings besir to the front with a tap, and the banner is cleared when besir opens — [#37](https://github.com/paul8004-lee/besir_global/pull/37)
- **Repeat saved as its rule** — a repeating activity is stored as one rule and its days are worked out when shown, so `every Monday` needs no end date and has no 182-day cap — [#38](https://github.com/paul8004-lee/besir_global/pull/38)
- **Example Delivery (Simulated)** — a simulated delivery app: ask for food to arrive at a set time, confirm one card, and the order, an optional meal entry and the estimated total sent to Example Budget follow; facts only, no advice — [#45](https://github.com/paul8004-lee/besir_global/pull/45)
- **Camera guard and 500 m place radius** — the camera snap refuses a photo until the capture session runs, and a sign photographed up to 500 m from its place now finds it (was 250 m) — [#49](https://github.com/paul8004-lee/besir_global/pull/49)
- **Time wheel commits what it shows** — opening an unset Start or End time on a new activity makes the time its wheel shows the value at once, so Add is live without turning the wheel — [#50](https://github.com/paul8004-lee/besir_global/pull/50)
- **Repeat legs follow their occurrence** — deleting a whole series keeps the travel legs of an occurrence already saved on its own, and after a time zone change the legs of repeat occurrences move onto the occurrence so the departure alarm fires at the right time — [#57](https://github.com/paul8004-lee/besir_global/pull/57)
- **Tap away closes the time wheel** — with a time wheel open on New Activity, an activity or New Event, a tap on the empty area outside the edit card closes it, the same as a tap on the card's own empty space — [#58](https://github.com/paul8004-lee/besir_global/pull/58)
- **Repeat legs get a missing travel time later** — a repeating activity's travel leg that a failed lookup left without a time gets one on a later fill, so its departure alarm is set; new legs copy the most common time of the series, not the first match — [#59](https://github.com/paul8004-lee/besir_global/pull/59)
- **Delete This Event Only comes first** — in both delete popovers of a repeating event (Edit Activity and the event detail screen), the one-occurrence choice now sits above Delete Entire Series, which cannot be undone — [#60](https://github.com/paul8004-lee/besir_global/pull/60)
- **Current Location on the return Destination** — the Destination of a return trip on New Activity and Edit Activity now offers Current Location like the Origin does, so getting back to where you stand needs no place search; with location permission off the existing note shows and the saved place stays — [#62](https://github.com/paul8004-lee/besir_global/pull/62)
- **A repeating activity block does not cross a day by drag** — dragging one occurrence of a repeating activity so that its start would land on another day now cancels the drag and the block springs back, instead of offering a series move that clamps to 23:59; a drag inside the same day opens the same choice as before, and one-time activities still move across days — [#63](https://github.com/paul8004-lee/besir_global/pull/63)
- **One action card from the partner's field list** — the simulated delivery partner names the fields of an order and of its result, and besir draws one fill-and-approve card from that list instead of a hand-written delivery card; the arrival time and the money in the result are acted on by kind, and the suggested delivery place also sees repeating activities — [#65](https://github.com/paul8004-lee/besir_global/pull/65)
- **A repeating activity's travel leg does not cross a day by drag** — dragging the outbound leg of one occurrence of a repeating activity so that the activity's start would land on another day now cancels the drag and the leg and activity spring back, the same rule as for the activity block; a drag inside the same day opens the same choice as before, and the return leg and one-time activities still move across days — [#66](https://github.com/paul8004-lee/besir_global/pull/66)
- **A cancelled day plan is said to be cancelled** — after Cancel on the Plan my day card, the agent is told the plan was cancelled and nothing was added, so its closing line should say so — [#69](https://github.com/paul8004-lee/besir_global/pull/69)
- **Tests for a one-time activity's leg drag across midnight** — regression tests that dragging a travel leg of a one-time activity across midnight changes only the dragged edge of the activity (the start for an outbound leg, the end for a return leg), and that dragging the activity block itself moves the whole activity; the reported whole-activity move did not reproduce on a leg drag, so no app code changed — [#71](https://github.com/paul8004-lee/besir_global/pull/71)
- **Chat keyboard stays down after a reply** — the chat message field gives up its focus and the system keyboard each time a reply re-enables the field; in the simulator walk the keyboard stayed down after a Confirm, a Cancel, a typed message and a plain reply, and one tap on the field raises it again; the chat sheet also shows its grab handle — [#73](https://github.com/paul8004-lee/besir_global/pull/73)
- **Replan follow-ups** — a tap on an old alert banner moves the pending alert, no tap looks up traffic again within five minutes, the late message is fixed text with no AI request, late minutes follow the clock, and opening the app reschedules alerts before the after-alert lookups — [#74](https://github.com/paul8004-lee/besir_global/pull/74)
- **Any simulated partner through one code path** — the app learns the simulated partners from a directory, the agent asks one with two tools, and besir draws one fill-and-approve card from the fields that partner names; a `time` result can be added to the schedule with a length the user sets, a `money` result is recorded as an estimated spend, and the table booking is the first partner on this path, with no app code of its own — [#72](https://github.com/paul8004-lee/besir_global/pull/72)
- **Unused calendar-sync code removed** — an unreachable calendar-sync row on New Event, an unused per-leg sync flag and a stale consent comment are gone; nothing the user sees changes — [#79](https://github.com/paul8004-lee/besir_global/pull/79)
- **A partner lists its own places for a field** — on a partner card, the typed place is looked up at the partner, which answers its own candidates (the table partner through Google Places on the Worker); the user taps one, even for an exact name, and the booked entry keeps its address and coordinates for a travel leg — [#80](https://github.com/paul8004-lee/besir_global/pull/80)

Some baseline files are edited in place, only for two reasons: the English localization of the app UI, and the split of the app and App Group identifiers from the earlier app. Both are listed as lines above when they land. Baseline files are never mass-reformatted, renamed or moved, so the diff shows old code and new code apart.

## Roadmap (not built yet)

- **be healthy sir** — fit workouts into the free time between plans
- **be fun sir** — suggest leisure and events that fit the day's schedule
- **be rich sir** — track spending tied to each plan
- **More connections** — real partner apps in place of the simulated reservation partner, and outgoing records to budget and health apps (Apple Health, Plaid, Ticketmaster and others), each one confirmed by the user
- **besir memory** — remembers the user's choices over time and shows recommendations that fit them; the user always makes the choice and besir never picks for them, so the app grows to fit each user
- **Auto mode** — an opt-in setting where besir carries out what it is confident about without a Confirm each time; anything that spends money, cancels a booking or places an order still waits for the user's tap
