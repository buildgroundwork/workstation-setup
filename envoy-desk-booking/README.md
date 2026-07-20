# Envoy auto desk booking

Books one specific Envoy desk for a range of dates, by replaying the same
private API calls Envoy's own web dashboard makes. Built because Envoy has
no public API, no recurring-booking feature, and this company removed
permanent desk assignment.

A Ruby CLI script (`book_desk.rb`), ported from a working DevTools-console
prototype. No gems beyond the Ruby standard library.

---

## Setup

1. Copy `.env.example` to `.env` and leave it untracked (already covered by
   `.gitignore` — never commit `.env`).
2. Get your session credentials from a logged-in browser tab (see "Auth" below)
   and fill in `ENVOY_COOKIE` / `ENVOY_CSRF_TOKEN` in `.env`.
3. Find your `--desk-id`, `--location-id`, etc. (see "Finding your config
   values" below) and either pass them as flags each run or wrap the command
   in a small local shell alias/script (not checked in) with your values baked
   in.

## Running it

```sh
export $(grep -v '^#' .env | xargs)   # load .env into the shell

./book_desk.rb \
  --location-id 86681 \
  --desk-id 5780977 \
  --user-id 8187613 \
  --company-id 1906 \
  --flow-id 295857 \
  --full-name "Adam Milligan" \
  --email adam.milligan@gusto.com \
  --start-date 2026-11-01 \
  --end-date 2027-12-31
```

Add `--dry-run` first to see which dates would be targeted without making any
requests. Add `--include-weekends` to book Sat/Sun too (default is weekdays
only). Run `./book_desk.rb --help` for the full flag list.

Re-running is always safe: already-booked days return `UNAVAILABLE` and are
skipped. To extend the range, just run again with a new `--end-date`.

---

## Auth (the only part that isn't a CLI flag, deliberately)

There is no API token to request — the script authenticates as *you* by
replaying your browser's session cookie and CSRF token, so those two values
are read only from the environment (`ENVOY_COOKIE`, `ENVOY_CSRF_TOKEN`),
never from a flag or a file the script writes. That keeps them out of shell
history and process listings, and means there is nothing credential-shaped
for this script to ever leak into source control — see "Safe to check in"
below.

**To extract them:**

1. Open Chrome, go to **dashboard.envoy.com/schedule**, confirm you're logged
   in, then hard-refresh (Cmd+Shift+R) so the tab holds a fresh token.
2. Open DevTools (Cmd+Option+J) → **Network** tab.
3. Click any request to `app.envoy.com`, open **Headers**.
4. Under **Request Headers**, copy the entire `cookie` value → this is
   `ENVOY_COOKIE`.
5. Within that same cookie string, find the `csrf_token=...;` segment and
   copy just its value → this is `ENVOY_CSRF_TOKEN`.

**These expire.** Envoy rotates `csrf_token` after every mutation and the
session cookie itself lapses after some period of inactivity or a forced
re-login. When the script starts failing with 401/403 on every day (it
already retries a few times first, in case the browser would've refreshed the
token on its own), re-extract both values from a fresh, logged-in tab and
re-run — already-booked days are skipped, so it resumes where it left off.

---

## Finding your config values

All of these were extracted from the DevTools Network tab while booking
manually.

| Flag              | What it is / how to find it |
|-------------------|------------------------------|
| `--location-id`   | Office location. In the cookie `location_id` and in most request URLs/params. |
| `--desk-id`        | The specific desk. Appears in the reservation POST body `relationships.desk.data.id`, and in the desk-availability URL `/a/rms/desks/{deskId}/reservations`. To find a different desk: book it once in the UI and read the reservation POST. |
| `--user-id`        | Your Envoy user id. In cookie `ajs_user_id`, and reservation body `relationships.user.data.id`. |
| `--company-id`     | In cookie `company_id`. Only used in the `x-envoy-context` header. |
| `--flow-id`        | The "Employee registration" flow id. Required on the invite. Read it from a UI-created invite's `relationships.flow.data.id`. |
| `--full-name`      | Required attribute on the invite. |
| `--email`          | Required attribute on the invite; also used in the invite-lookup filter. |
| `--start-date` / `--end-date` | Date range, inclusive, `YYYY-MM-DD`, local time. |

### To adapt for a different person/desk

Replace `--location-id`, `--desk-id`, `--user-id`, `--company-id`,
`--flow-id`, `--full-name`, `--email`. The reliable way to get all of them:
have that person log into Envoy, open DevTools → Network, book one day
through the UI, and read the values out of the invite POST and reservation
POST (see "The booking flow" below).

---

## The booking flow (how the API actually works)

Booking a desk for one day is **two POSTs**, mirroring the UI's "schedule the
day" then "assign a desk":

**Step 1 — create an "invite"** (this is Envoy's term for a scheduled day):

```
POST https://app.envoy.com/a/visitors/api/v3/invites
Content-Type: application/vnd.api+json
X-CSRF-Token: <csrf_token cookie value>
X-Envoy-Context: {"fe_name":"dashboard","scope":"location","location_id":"...","user_id":"...","company_id":"..."}

{"data":{
  "type":"invites",
  "attributes":{
    "expected-arrival-time":"2026-11-03T05:00:00.000Z",
    "full-name":"...",
    "email":"..."
  },
  "relationships":{
    "location":{"data":{"type":"locations","id":"..."}},
    "flow":{"data":{"type":"flows","id":"..."}}
  }
}}
```

Returns the new invite's `id`.

**Step 2 — create the "reservation"** linking your desk to that invite:

```
POST https://app.envoy.com/a/rms/reservations
Content-Type: application/vnd.api+json
X-CSRF-Token: <csrf_token cookie value>
X-Envoy-Context: {...same...}

{"data":{
  "type":"reservations",
  "attributes":{
    "start-time":1793682000,
    "end-time":1793768340,
    "check-in-time":null,"check-out-time":null,"canceled-at":null,
    "user-email":null,"is-partial-day":false
  },
  "relationships":{
    "desk":{"data":{"type":"desks","id":"..."}},
    "location":{"data":{"type":"locations","id":"..."}},
    "invite":{"data":{"type":"invites","id":"<from step 1>"}},
    "user":{"data":{"type":"users","id":"..."}}
  }
}}
```

The script also does two GET pre-checks (look up an existing invite for the
day; check whether the desk is already reserved) so re-runs skip work.

### Time fields
- Reservation `start-time` = local midnight (epoch sec); `end-time` = local
  23:59:00 (note: **:00**, not :59 — matches what the UI sends).
- Invite `expected-arrival-time` = start-of-day as a UTC ISO string, e.g.
  midnight EST → `...T05:00:00Z`.
- Day boundaries are computed in **local time**, which must match the office
  timezone for the windows to be right. DST is handled automatically since
  it's computed via real `Time` objects.

---

## Field-by-field debugging history (so a new agent doesn't repeat it)

Each of these was discovered by making the script print the server's error
body on failure, then fixing one field at a time:

- **401 on POST** → missing `X-CSRF-Token` header. Added it (read fresh each time).
- **400 "required parameter, type, is missing"** → JSON:API `data` object needs `"type":"invites"`.
- **400 "start-time is not allowed"** → the invite does **not** take start/end times (those belong on the reservation, not the invite). Removed them.
- **500** → invite needs `location` and `flow` relationships. Added them.
- **400 "creator is not allowed"** → don't send `creator`; the server sets it from auth. Removed it.
- **422 "full-name can't be blank"** → invite needs `full-name` (and `email`) attributes. Added them.
- ✅ **booked.**

If Envoy changes its API and a new required field appears, the script already
prints the server's error text on invite/reservation failure — read that, add
the field, re-run.

### Known non-fatal quirk
The desk-availability GET (`/a/rms/desks/{deskId}/reservations?...`) sometimes
returns **404** for far-future dates. That's fine: the script treats it as
"couldn't check," proceeds, and the reservation POST itself returns a **422
"desk unavailable" (code 1002)** if the day is already booked — which the
script reports as `UNAVAILABLE` and skips. So double-booking is still
prevented even when the pre-check 404s.

---

## Result statuses in the output

- `booked` — newly booked.
- `already booked - skipped` — pre-check found your existing reservation.
- `UNAVAILABLE - desk already taken (likely already yours)` — reservation POST
  returned 422/1002. Usually your own prior booking. **If it appears on a day
  you did NOT book, someone else took the desk** — the one case worth acting on.
- `FAILED ... (<status>): <server error>` — includes the server's message.

---

## Safe to check in

- The script takes no credentials as flags — only `--location-id`, desk
  id, etc., which identify *what* to book, not *who's* making the request.
- Auth lives in `ENVOY_COOKIE` / `ENVOY_CSRF_TOKEN`, read from the
  environment only. The script never writes them to a file or prints them
  (error output is truncated to the server's response body, which doesn't
  echo request headers).
- `.env` (where you'd typically put real values) is listed in `.gitignore`.
  Only `.env.example`, with blank placeholders, is tracked.
- Your name/email/desk/location ids in the example command above are not
  secrets — they're only useful to someone who could already see your Envoy
  account — but if that bothers you, keep them in your own untracked wrapper
  script instead of shell history.

---

## Caveats / ethics

This uses Envoy's private, undocumented API, not a supported integration. It
can break if Envoy changes their frontend, and may not strictly align with
Envoy's terms of service (it's automating your own routine booking of your own
desk). Spot-check the schedule periodically rather than assuming it's still
working.
