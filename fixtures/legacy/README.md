# Synthetic legacy storage examples

These files are examples of the **stored JSON value** for each key, not exports of anyone's storage. They are deliberately small and use invented courses, players, and discs. The current storage keys and writers stay unchanged. Separate web and app parsers and their tests belong to C4.

| Example | Actual writer and stored shape |
| --- | --- |
| [web-rounds.json](web-rounds.json) | `birdie_finder_web/scorecard.html` calls `BF.rounds.save(...)` when **Save to profile** is clicked. `birdie_finder_web/assets/app.js` stores a plain array under browser `localStorage` key `bf_rounds_v1`, newest first, and keeps **only the latest 50 saved rounds**. In-progress scores live only in page memory. |
| [app-rounds.json](app-rounds.json) | `birdie_finder_app/src/state/round.ts` uses Zustand `persist` with `createJSONStorage(() => AsyncStorage)` under app key `bf_rounds_v1`. The stored JSON has `state.live`, `state.history`, and `version: 0`. Functions are omitted. `live.holes` is optional in the TypeScript type. |
| [app-bag.json](app-bag.json) | `birdie_finder_app/src/state/bag.ts` uses the same Zustand/AsyncStorage wrapper under `bf_bag_v1`. It stores copied disc objects plus `seeded`; optional `pic` and `stability` may be absent. `bf_cart_v1` on the web is a shopping cart and is not a bag import source. |

The first two entries of `web-rounds.json` are separate array positions with identical dates and scores, in fact identical content. They must receive separate stable manifest UUIDs. The first two `app-rounds.json` history entries also share their date and scores but have distinct legacy IDs. Missing `courseId`, `layout`, and `rel` on the third web entry and missing `pars` on the third app history entry model incomplete older records; an importer must mark unresolved facts as unknown or send the record for review. It must never fill missing par or scores with guesses. The web date string has no time zone or precise time.
