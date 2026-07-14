import {
  createContext,
  useContext,
  useEffect,
  useReducer,
  useRef,
  type Dispatch,
  type ReactNode,
} from "react";
import {
  activityReducer,
  initialActivityState,
  type ActivityAction,
  type ActivityState,
} from "../lib/activity-store";
import { sampleSchema, sessionSchema, type LiveSession } from "../lib/contracts";
import { reconnectDelay, streamSSE } from "../lib/sse";

type LiveContextValue = {
  state: ActivityState;
  session?: LiveSession;
};

const LiveContext = createContext<LiveContextValue | undefined>(undefined);

export function LiveProvider({ overlayId, children }: { overlayId: string; children: ReactNode }) {
  const [state, dispatch] = useReducer(activityReducer, initialActivityState);
  const [session, setSession] = useReducer(
    (_: LiveSession | undefined, next: LiveSession | undefined) => next,
    undefined,
  );
  const latestEnvelope = useRef<string | undefined>(undefined);

  useEffect(() => {
    const controller = new AbortController();
    void runLiveClient(
      overlayId,
      controller.signal,
      dispatch,
      (next) => {
        setSession(next);
        latestEnvelope.current = next.snapshot.latest?.envelopeId;
      },
      latestEnvelope,
    );
    return () => controller.abort();
  }, [overlayId]);

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (
        state.connection === "live" &&
        state.latest?.state === 1 &&
        state.sampleReceivedAt &&
        Date.now() - state.sampleReceivedAt > 20_000
      ) {
        dispatch({ type: "connection", connection: "stale" });
      }
    }, 5000);
    return () => window.clearInterval(interval);
  }, [state.connection, state.latest?.state, state.sampleReceivedAt]);

  return <LiveContext value={{ state, session }}>{children}</LiveContext>;
}

async function runLiveClient(
  overlayId: string,
  signal: AbortSignal,
  dispatch: Dispatch<ActivityAction>,
  onSession: (session: LiveSession) => void,
  latestEnvelope: { current: string | undefined },
) {
  let session: LiveSession | undefined;
  let attempt = 0;
  let reset = false;
  while (!signal.aborted) {
    try {
      if (!session || reset || Date.parse(session.expiresAt) - Date.now() < 30_000) {
        dispatch({ type: "connection", connection: session ? "reconnecting" : "connecting" });
        session = await fetchSession(overlayId, signal);
        onSession(session);
        dispatch({ type: "bootstrap", session });
        reset = false;
        attempt = 0;
        if (session.viewerToken === "fixture-viewer-token") return;
      }

      const streamController = new AbortController();
      const stop = () => streamController.abort();
      signal.addEventListener("abort", stop, { once: true });
      const refreshTimer = window.setTimeout(
        () => streamController.abort(),
        Math.max(0, Date.parse(session.expiresAt) - Date.now() - 20_000),
      );
      try {
        const headers: Record<string, string> = {
          Accept: "text/event-stream",
          Authorization: `Bearer ${session.viewerToken}`,
        };
        if (latestEnvelope.current) headers["Last-Event-ID"] = latestEnvelope.current;
        const url = `${session.apiPublicUrl}/v1/channels/${encodeURIComponent(session.channelSlug)}/stream`;
        const response = await fetch(url, {
          headers,
          cache: "no-store",
          signal: streamController.signal,
        });
        await streamSSE(response, (message) => {
          if (message.event === "reset" || message.event === "activity") {
            reset = true;
            streamController.abort();
            return;
          }
          if (message.event !== "sample") return;
          const sample = sampleSchema.parse(JSON.parse(message.data));
          latestEnvelope.current = message.id ?? sample.envelopeId;
          dispatch({ type: "sample", sample });
          attempt = 0;
        });
      } finally {
        window.clearTimeout(refreshTimer);
        signal.removeEventListener("abort", stop);
      }
      if (Date.parse(session.expiresAt) - Date.now() < 30_000) session = undefined;
      if (!reset) {
        dispatch({ type: "connection", connection: "reconnecting" });
        await wait(reconnectDelay(attempt++), signal);
      }
    } catch (error) {
      if (signal.aborted) return;
      if (reset) continue;
      dispatch({ type: "connection", connection: "reconnecting" });
      await wait(reconnectDelay(attempt++), signal);
      if (error instanceof SyntaxError) session = undefined;
    }
  }
}

async function fetchSession(overlayId: string, signal: AbortSignal) {
  const response = await fetch(`/api/live/${encodeURIComponent(overlayId)}/session`, {
    method: "POST",
    headers: { Accept: "application/json" },
    cache: "no-store",
    signal,
  });
  if (!response.ok)
    throw new Error(response.status === 404 ? "Overlay not found" : "Live session unavailable");
  return sessionSchema.parse(await response.json());
}

function wait(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timer = window.setTimeout(resolve, milliseconds);
    signal.addEventListener(
      "abort",
      () => {
        window.clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });
}

export function useLive() {
  const value = useContext(LiveContext);
  if (!value) throw new Error("useLive must be used inside LiveProvider");
  return value;
}
