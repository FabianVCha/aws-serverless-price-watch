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

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';

const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

export const handler = async (event) => {
  // Keep this line: it is the fastest way to see the proxy event's real shape.
  console.log(JSON.stringify({
    level: 'debug',
    message: 'request',
    method: event.httpMethod,
    resource: event.resource,
    path: event.path,
    pathParameters: event.pathParameters ?? null,
    bodyType: typeof event.body,
    bodyLength: typeof event.body === 'string' ? event.body.length : null,
    keys: Object.keys(event).join(','),
  }));

  switch (`${event.httpMethod} ${event.resource}`) {
    case 'POST /observations':
      // R1: store one observation, at most once per (sku, capturadoEn).
      {let body;
        try{
          body = JSON.parse(event.body);
        } catch {
          return json(400, { error: 'json_invalido'});
        }
        if(body.precio > 0  && typeof body.precio === 'number'){
          if(!Number.isNaN(Date.parse(body.capturadoEn)))
            {if(body.sku && body.sku.length>=3 && body.sku.length<=40){
              try{
                await doc.send(new PutCommand({
                  TableName: process.env.TABLE_NAME,
                  Item: {
                    // One partition per product, one item per observation:
                    // the history is the set of items, not an array inside one.
                    pk: `SKU#${body.sku}`,
                    sk: `OBS#${body.capturadoEn}`,
                    precio: body.precio,
                    moneda: body.moneda,
                    url: body.url,
                    capturadoEn: body.capturadoEn,
                  },
                  // Check and write are one atomic operation, so the same
                  // observation sent twice is rejected, never duplicated.
                  ConditionExpression: 'attribute_not_exists(pk)',
                }));
                return json(201, {creado: true });
              }catch(err){
                // A duplicate is a normal outcome, not a failure.
                if(err.name === 'ConditionalCheckFailedException'){
                  return json(200, {duplicado: true});
                }
                throw err;
              }
              
              }
            };
          };
        // Anything that failed validation is rejected, never stored.
        return json(400, {received: "error"})}
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
