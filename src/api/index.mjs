// REST API entry point.
//
// One function serves all three routes, exactly like a real API Gateway
// proxy integration. Route on `event.resource` and `event.httpMethod`.
//
//   POST /observations           -> createObservation   (spec R1)
//   GET  /products/{sku}         -> getProduct          (spec R2)
//   PUT  /products/{sku}         -> setTarget           (spec R3)
//
// The proxy event gives you: event.body (a STRING, not an object),
// event.pathParameters, event.httpMethod, event.resource.
//
// Verified on the local emulator: the AWS SDK v3 is already inside the Node
// runtime, so `import { DynamoDBClient } from '@aws-sdk/client-dynamodb'`
// works without a node_modules folder. Do NOT pass an endpoint override: the
// emulator already routes the client, and an override breaks the TLS check.

export const handler = async (event) => {
  // Keep this line: it is the fastest way to see the proxy event's real shape.
  console.log(JSON.stringify({
    level: 'debug',
    message: 'request',
    method: event.httpMethod,
    resource: event.resource,
    path: event.path,
    pathParameters: event.pathParameters ?? null,
  }));

  switch (`${event.httpMethod} ${event.resource}`) {
    case 'POST /observations':
      // TODO(R1): validate, write idempotently, alert when below target.
      break;
    case 'GET /products/{sku}':
      // TODO(R2): read the history and return the stats.
      break;
    case 'PUT /products/{sku}':
      // TODO(R3): store the target for that sku.
      break;
    default:
      return json(404, { error: 'not_found', resource: event.resource });
  }

  return json(501, {
    error: 'not_implemented',
    route: `${event.httpMethod} ${event.resource}`,
  });
};

function json(statusCode, body) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  };
}
