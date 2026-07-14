export type SSEMessage = { event: string; id?: string; data: string };

export class SSEParser {
  private buffer = "";
  private pendingCarriageReturn = false;

  push(chunk: string, flush = false): SSEMessage[] {
    let input = this.pendingCarriageReturn ? `\r${chunk}` : chunk;
    this.pendingCarriageReturn = false;
    if (!flush && input.endsWith("\r")) {
      input = input.slice(0, -1);
      this.pendingCarriageReturn = true;
    }
    this.buffer += input.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
    const events: SSEMessage[] = [];
    let boundary = this.buffer.indexOf("\n\n");
    while (boundary >= 0) {
      const block = this.buffer.slice(0, boundary);
      this.buffer = this.buffer.slice(boundary + 2);
      const event = parseBlock(block);
      if (event) events.push(event);
      boundary = this.buffer.indexOf("\n\n");
    }
    if (flush && this.buffer) {
      const event = parseBlock(this.buffer);
      this.buffer = "";
      if (event) events.push(event);
    }
    return events;
  }
}

function parseBlock(block: string): SSEMessage | undefined {
  let event = "message";
  let id: string | undefined;
  const data: string[] = [];
  for (const line of block.split("\n")) {
    if (!line || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    const value = colon < 0 ? "" : line.slice(colon + 1).replace(/^ /, "");
    if (field === "event") event = value;
    if (field === "id" && !value.includes("\0")) id = value;
    if (field === "data") data.push(value);
  }
  if (data.length === 0) return undefined;
  return id === undefined ? { event, data: data.join("\n") } : { event, id, data: data.join("\n") };
}

export async function streamSSE(response: Response, onMessage: (message: SSEMessage) => void) {
  if (!response.ok || !response.body)
    throw new Error(`Live stream unavailable (${response.status})`);
  const parser = new SSEParser();
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      for (const message of parser.push(value)) onMessage(message);
    }
    for (const message of parser.push("", true)) onMessage(message);
  } finally {
    reader.releaseLock();
  }
}

export function reconnectDelay(attempt: number, random = Math.random()) {
  return Math.min(15_000, 500 * 2 ** Math.min(attempt, 5)) * (0.75 + random * 0.5);
}
