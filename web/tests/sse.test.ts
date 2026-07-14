import { describe, expect, it } from "vite-plus/test";
import { SSEParser, reconnectDelay } from "../src/lib/sse";

describe("streaming SSE parser", () => {
  it("parses arbitrary chunks, comments, and multiple events", () => {
    const parser = new SSEParser();
    expect(parser.push(": heart\r\nid: 123\r\nevent: sam")).toEqual([]);
    expect(
      parser.push('ple\r\ndata: {"ok":\r\ndata: true}\r\n\r\nevent: reset\ndata: {}\n\n'),
    ).toEqual([
      { id: "123", event: "sample", data: '{"ok":\ntrue}' },
      { event: "reset", data: "{}" },
    ]);
  });

  it("does not turn a CRLF split across chunks into an event boundary", () => {
    const parser = new SSEParser();
    expect(parser.push("event: sample\r")).toEqual([]);
    expect(parser.push("\ndata: {}\r")).toEqual([]);
    expect(parser.push("\n\r")).toEqual([]);
    expect(parser.push("\n")).toEqual([{ event: "sample", data: "{}" }]);
  });

  it("bounds exponential reconnect delay", () => {
    expect(reconnectDelay(0, 0)).toBe(375);
    expect(reconnectDelay(20, 1)).toBe(18_750);
  });
});
