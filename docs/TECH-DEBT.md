# Pending work

Deliberate debt. Every item here is a decision, not an accident: it was left
on purpose while learning, and it comes back at the end of the exercise so the
reason for the change is visible in the diff.

Rule: an item is closed only when the change is made **and** the test that
would catch its absence exists.

---

## 1. The POST case nests four levels of `if`

**What:** `createObservation` is written as `if / if / if / try` inside one
another, with the rejection `return` after the whole nest.

**Why it matters:** every requirement added from here (R3 sends to SQS, and
later rules) has to fit inside that nest or duplicate the tail. The deeper the
nest, the easier it is to send a rejected payload down the success path - that
exact bug already happened once: the handler answered `200` to a negative
price.

**Eventually:** validate into named booleans, reject once with an early return,
then run the write. Same behaviour, half the indentation, and one exit per
outcome.

**How to check it is done:** the POST case has a single `return json(400, ...)`
placed before the write, and `make e2e` is still green.

---

## 2. Two different shapes for a rejection

**What:** `{ error: 'json_invalido' }` for a body that is not JSON, but
`{ received: 'error' }` for everything that fails validation.

**Why it matters:** a caller cannot tell which field was wrong, and
`received` is not an error field - it reads like a success. When the scraper
starts sending real traffic, the first debugging session pays for this.

**Eventually:** one shape, `{ error: '<reason>' }`, with a distinct reason per
rule (`sku_invalido`, `precio_invalido`, `fecha_invalida`).

**How to check it is done:** every rejection test asserts the reason, not just
the status code.

---

## 3. `moneda` and `url` are stored without any validation

**What:** they are copied straight from the payload. They can be missing, or be
a number, or be an array.

**Why it matters:** R2 averages `precio` across everything it finds. Two
observations in different currencies, or one with `moneda` missing, produce an
average that is arithmetically correct and semantically garbage.

**Eventually:** require `moneda` (3 letters) and make `url` a valid URL, or
drop `url` from what R2 aggregates.

**How to check it is done:** an observation without `moneda` is rejected.

---

## 4. `capturadoEn` is stored exactly as it arrives

**What:** the string becomes part of the sort key, with no normalisation.

**Why it matters:** the same instant written two ways
(`2026-11-14T20:00:00Z` and `2026-11-14T15:00:00-05:00`) produces two different
items. The conditional write cannot see them as duplicates because their keys
differ, so the history quietly double-counts.

**Eventually:** normalise to UTC ISO-8601 before building the key, and reject
anything that is not parseable.

**How to check it is done:** sending the same instant in two time zones leaves
one item, and the second answer says `duplicado: true`.

---

## 5. The rejection paths have no tests

**What:** `tests/e2e.sh` covers the happy path and one table write. The
thirteen cases that matter were run by hand once.

**Why it matters:** every item above is a future refactor, and a refactor
without tests reopens the "invalid payload answered 200" bug without anyone
noticing. A test that is never written protects nothing.

**Eventually:** one assertion per rule in the R1 block of `tests/e2e.sh`:
short sku, long sku, missing sku, price as text, price zero, negative price,
impossible date, garbage date, non-JSON body, duplicate, plus the two
acceptance edges (3 characters, 40 characters).

**How to check it is done:** break the rule on purpose and watch the test fail.

---

## 6. `Query` pagination is not handled

**What:** not written yet - it belongs to R2.

**Why it matters:** a `Query` returns at most 1 MB and hands back a
`LastEvaluatedKey` for the rest. A product with a long history will return a
partial page, and a minimum computed from a partial page is wrong without
saying so.

**Eventually:** loop while `LastEvaluatedKey` exists, or record the limit as a
known limitation of the exercise.

**How to check it is done:** a test that inserts enough observations to exceed
one page and still gets the right minimum.

---

## 7. The request log line is unconditional

**What:** the handler logs the event shape on every single request.

**Why it matters:** it is the best debugging tool in this repo, and it is also
what fills the log group in a real deployment. Both things are true; keep it
until the exercise is done, then decide.

**Eventually:** drop it, or gate it behind an environment variable.

---

## 8. Deliberate non-goals

Recorded so nobody "fixes" them by accident:

- No IAM policy tests: the emulator does not evaluate policies, so a passing
  test would prove nothing.
- No authentication, no API keys, no usage plans.
- No second table: `TARGET` items live in the same table on purpose.
- No TypeScript until the AWS behaviour is understood.
