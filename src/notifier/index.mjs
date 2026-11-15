// SQS consumer for price alerts.
//
// Invoked by the event source mapping declared in template.yaml, not by HTTP.
// The batch arrives in event.Records, each with a .body string.
//
// TODO(R4): process every record and return the failures, otherwise SQS
// deletes a message you never handled:
//
//   return { batchItemFailures: [{ itemIdentifier: record.messageId }] }
//
// Remember that SQS delivers at least once: the same message CAN arrive twice.

export const handler = async (event) => {
  const records = event.Records ?? [];
  console.log(
    JSON.stringify({
      level: 'info',
      message: 'batch_received',
      count: records.length,
    }),
  );

  // TODO(R4): for each record, parse JSON.parse(record.body) and act on it.

  return { batchItemFailures: [] };
};
