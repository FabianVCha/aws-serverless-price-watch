# Price Watch

A small serverless service that tracks product prices, keeps the history, and
raises an alert when a price drops below a target. It exists to demonstrate
real AWS serverless design — API Gateway, Lambda, DynamoDB, SQS, an event
source mapping and CloudFormation — while running entirely on a laptop against
a local AWS emulator.

The repository ships as a **skeleton with a red harness**: the infrastructure
is complete, the handlers are stubs, and `make e2e` fails until the
requirements in [spec/SPEC.md](spec/SPEC.md) are implemented. The harness only
proves the happy path; the assertions that matter are part of the exercise.

## Architecture

```
  scraper  --POST /observations-->  API Gateway  -->  Lambda "api"  -->  DynamoDB
                                                           |
                                                           +-- price <= target --> SQS "alerts"
                                                                                       |
                                                                            event source mapping
                                                                                       |
                                                                                Lambda "notifier"

  GET  /products/{sku}          -> last, min, max, average, sample count
  PUT  /products/{sku}          -> set the threshold for that sku
```

## Prerequisites

- `aws-emulator` on `PATH` (Arch/CachyOS: `paru -S aws-emulator-bin`)
- AWS CLI v2 (`pacman -S aws-cli-v2`)
- `python3` (the scripts use its standard library to build the zips)
- No AWS account, no Docker, no `npm install`

## Quick start

```bash
make up        # start the emulator and write .emulator.env (+ .emulator.env.fish)
make deploy    # package both functions, upload them, create the stack
make e2e       # the full cycle against the minimal harness (red until you implement the spec)
make destroy   # delete the stack and the artifact bucket
make down      # stop the emulator
```

To use the AWS CLI in your own terminal after `make up`, source the file for
your shell — they are two files because the shells disagree on how to unset a
variable:

```bash
source .emulator.env        # bash, zsh
```

```fish
source .emulator.env.fish   # fish: `unset` does not exist there
```

`make e2e` does the whole cycle by itself: up, deploy, test, down.

## Repository map

```
template.yaml          the whole infrastructure: role, table, queue, functions, API, mapping
spec/SPEC.md            the exercise: requirements, acceptance criteria, order of work
src/api/index.mjs       the router for the three routes (stub)
src/notifier/index.mjs  the SQS consumer (stub)
scripts/emulator.sh     start/stop the emulator and write the env file
scripts/deploy.sh       package, upload, create or update the stack, poll it
scripts/destroy.sh      delete the stack and the bucket
tests/e2e.sh            the acceptance contract, one block per requirement
```

## How the API is tested

The emulator has **no execute-api URL**, so there is nothing to `curl`. Tests
go through the real AWS API for this:

```bash
aws apigateway test-invoke-method --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" --http-method POST --body '{"sku":"X"}'
```

It really invokes the Lambda with a proxy event (`body` as a **string**,
`httpMethod`, `path`, `pathParameters`) and returns the status, the body and an
execution log. `template.yaml` also leaves out a Deployment and a Stage for the
same reason; add them when you care about a real HTTP endpoint.

## What is verified on the local emulator

Facts measured on `aws-emulator` 1.0.322, not copied from documentation:

| Fact | Value |
| --- | --- |
| Lambda runtimes that execute | `nodejs*` and `python*` only |
| Node version inside the function | `v22.0.0` |
| AWS SDK v3 inside the runtime | dynamodb, lib-dynamodb, sqs, sns, s3, sts, util-dynamodb |
| `@aws-sdk/credential-provider-node` | **not available** |
| Endpoint, CA and credentials in the function env | not injected; the SDK call is routed anyway |
| First write after `CreateTable` | fails for ~3 s until the table is `ACTIVE` |
| SQS -> Lambda event source mapping | works, ~1 s, standard `Records` shape |
| `apigateway test-invoke-method` | works, invokes the function for real |
| CloudFormation create/delete stack | works, with `CAPABILITY_NAMED_IAM` |
| Logs | `/aws/lambda/<function-name>`, readable with `aws logs tail` |

### Traps that will bite you

1. **Table readiness.** `CreateTable` returns before the data plane accepts
   writes. A write right after it fails with `ResourceNotFoundException` even
   though `list-tables` shows the table. Poll `describe-table` until `ACTIVE`.
   Real AWS behaves the same way (CREATING -> ACTIVE), so this is practice,
   not a workaround.
2. **Table name length.** DynamoDB rejects names shorter than 3 characters.
3. **No endpoint override.** Inside a function, `new DynamoDBClient({})`
   already reaches the emulator. Passing a custom `endpoint` breaks the TLS
   check against its self-signed certificate.
4. **`get-queue-attributes`** accepts one attribute name per call.
5. **`get-resources`** can return an empty list right after the API is created.
   Retry before resolving the root resource.

## What this is not

- Not production: the emulator keeps everything in RAM and deletes it on stop.
- Not a security test: the emulator does not evaluate IAM policies.
- Not multi-region or multi-account: one of each per emulator process.
- Not Rust: `provided.al2023` is refused by this emulator (`InvalidRuntimeException`).
  Rust on Lambda needs LocalStack instead.
