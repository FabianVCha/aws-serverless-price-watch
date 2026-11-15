# Price Watch - exercise specification

The infrastructure in `template.yaml` is complete. The two handlers are stubs.
Make `make e2e` pass without editing `tests/e2e.sh` and without touching the
acceptance criteria below.

Time budget: 6-10 hours. If it takes 2, you copied something.

## Data model

One DynamoDB table, one item per observation:

```
pk = SKU#<sku>
sk = OBS#<capturedAt>        # the observation
sk = TARGET                  # the threshold for that sku
```

Choose the attribute names, but keep the key shape: the tests query by `pk`
with the value `SKU#<sku>`.

## R1 - Ingest is idempotent

`POST /observations`

```json
{"sku":"MLA123","precio":89.9,"moneda":"COP","url":"https://...","capturadoEn":"2026-11-14T20:00:00Z"}
```

Rules: `sku` 3-40 characters, `precio` a number greater than 0, `capturadoEn`
ISO-8601. Store one item per `(sku, capturadoEn)` pair.

Acceptance:
- the first call answers 200 or 201;
- the same body sent twice answers `{"duplicado": true}` the second time;
- the table holds exactly one item for that sku.

Think before coding: a conditional write, not read-then-write. Why?

## R2 - Statistics

`GET /products/{sku}` returns:

```json
{"ultimoPrecio":120,"precioMinimo":80,"precioMaximo":120,"promedio":100,"muestras":3}
```

Acceptance: three observations at 100, 80 and 120 give min 80, max 120, last
120, samples 3.

Use `Query` on the partition key. A `Scan` that filters in code is wrong here,
and you should be able to say why.

## R3 - Target and alert

`PUT /products/{sku}` with `{"precioObjetivo": 90}` stores the threshold in the
same table (that is the `sk = TARGET` item). When an incoming observation has
`precio <= precioObjetivo`, send a message to the alerts queue with at least
`sku`, `precio` and `objetivo`.

Acceptance: with a target of 90, an observation of 89.9 leaves a message in the
queue that `receive-message` can read.

The API function must never fail the request because the queue failed: the
observation is already stored.

## R4 - Asynchronous consumer

The `notifier` function is invoked by the event source mapping, not by HTTP.
For every record it must log a JSON line that contains `alert_processed` and
the `sku`, and it must return the batch's failures:

```js
return { batchItemFailures: [{ itemIdentifier: record.messageId }] };
```

Acceptance: `aws logs tail /aws/lambda/price-watch-notifier` shows
`alert_processed`, and the queue ends up empty.

SQS delivers **at least once**. The same message can arrive twice, and a batch
of five can contain one poisoned record. Your code must survive both.

## R5 - Declarative infrastructure

Everything is declared in `template.yaml`. `make deploy` creates it,
`make destroy` deletes it and leaves nothing behind. Do not add resources with
ad-hoc CLI commands inside the Makefile.

## R6 - One command

`make e2e` starts the emulator, deploys, runs `tests/e2e.sh` and stops the
emulator. Exit code 0 only when every requirement passes, from a cold start.

`tests/e2e.sh` ships as a **minimal harness**: one call and one coarse
assertion per requirement, happy path only. It is not the acceptance suite.
These assertions are missing and are yours to write, in that file or beside it:

- a repeated observation answers `duplicado: true` **and** leaves one item
- the statistics are exactly 80 / 120 / 120 / 3 for prices 100, 80, 120
- the alert body carries `sku`, `precio` and `objetivo`
- a record that throws stays in the queue (partial batch failure)
- a message delivered twice does not double-count an alert
- an invalid payload is rejected (short sku, price <= 0, bad timestamp)

A requirement is only done when its assertion exists and fails without the
code that satisfies it.

## Rules

- No SAM, no Serverless Framework, no CDK. One template and the AWS CLI.
- No TypeScript yet. Learn AWS first; the types come later as a refactor.
- No authentication, no GSI, no pagination, no frontend.
- Do not test IAM: the emulator does not evaluate policies, so any test would
  prove nothing.
- If you cannot explain why a line exists, that line does not belong.

## Suggested order

1. **Spike (30-45 min).** `make up`, `make deploy`, look at the stack outputs,
   invoke `POST /observations` once and read the event from the CloudWatch log.
   Understand the proxy event before writing logic.
2. **Vertical slice.** R1 only: validate, write one item, prove it with a scan.
   Hit the table-readiness trap here.
3. **R1 complete.** Idempotency with a conditional write.
4. **R2.** Query and reduce. No Scan.
5. **R3 + R4.** Queue, mapping, partial batch failures.
6. **R6, README, publish.**

## Questions you must be able to answer at the end

1. Why `pk = SKU#<sku>` and not `pk = <sku>`?
2. Why a conditional write instead of read, compare, write?
3. Why a queue instead of calling the notifier directly from the API function?
4. If the same SQS message arrives twice, what does your code do?
5. If one record of a five-record batch keeps failing, what must happen?
6. What exactly changes to deploy this to real AWS?
