import type {
  ConnectionState,
  FullRoute,
  LiveSession,
  RoutePoint,
  Sample,
  Snapshot,
} from "./contracts";
import { speedPace, validPace } from "./format";

type PacePoint = { elapsed: number; distance: number };
const MAX_ROUTE_POINTS = 5000;

export type ActivityState = {
  connection: ConnectionState;
  channelId?: string;
  activityId?: string;
  latest?: Sample;
  latestEnvelopeId?: string;
  route: RoutePoint[];
  seenEnvelopeIds: Set<string>;
  paceWindow: PacePoint[];
  rollingPace?: number;
  locationPolicy?: FullRoute["locationPolicy"];
  sampleReceivedAt?: number;
  viewerTokenExpiresAt?: string;
  error?: string;
};

export type ActivityAction =
  | { type: "bootstrap"; session: LiveSession; now?: number }
  | { type: "sample"; sample: Sample; now?: number }
  | { type: "connection"; connection: ConnectionState; error?: string }
  | { type: "reset" };

export const initialActivityState: ActivityState = {
  connection: "connecting",
  route: [],
  seenEnvelopeIds: new Set(),
  paceWindow: [],
};

export function activityReducer(state: ActivityState, action: ActivityAction): ActivityState {
  if (action.type === "reset") return { ...initialActivityState };
  if (action.type === "connection") {
    return { ...state, connection: action.connection, error: action.error };
  }
  if (action.type === "bootstrap") {
    const { snapshot, route } = action.session;
    const activityChanged = snapshot.activityId !== state.activityId;
    const base = activityChanged ? initialActivityState : state;
    const bootstrappedRoute = dedupeRoute(route.points);
    const seen = new Set<string>();
    for (const point of bootstrappedRoute) seen.add(point.envelopeId);
    if (snapshot.latest) seen.add(snapshot.latest.envelopeId);
    const withSnapshot = applyLatest(
      {
        ...base,
        connection:
          activityChanged || !base.latest
            ? snapshot.latest?.state === 4
              ? "ended"
              : "live"
            : base.connection,
        channelId: snapshot.channelId,
        activityId: snapshot.activityId ?? undefined,
        route: bootstrappedRoute,
        seenEnvelopeIds: seen,
        locationPolicy: route.locationPolicy,
        viewerTokenExpiresAt: action.session.expiresAt,
      },
      snapshot.latest ?? undefined,
      (action.now ?? Date.now()) - (snapshot.latestSampleAgeMilliseconds ?? 0),
      false,
    );
    return withSnapshot;
  }

  if (state.seenEnvelopeIds.has(action.sample.envelopeId)) return state;
  return applyLatest(state, action.sample, action.now, true);
}

function applyLatest(
  state: ActivityState,
  incoming: Sample | undefined,
  now = Date.now(),
  appendLocation: boolean,
): ActivityState {
  if (!incoming) return state;
  const seen = new Set(state.seenEnvelopeIds);
  seen.add(incoming.envelopeId);
  while (seen.size > 10_000) seen.delete(seen.values().next().value as string);
  const route = appendLocation ? appendRoutePoint(state.route, incoming) : state.route;
  if (
    state.latest &&
    Date.parse(incoming.phoneReceivedAt) < Date.parse(state.latest.phoneReceivedAt)
  ) {
    return {
      ...state,
      latestEnvelopeId: incoming.envelopeId,
      route,
      seenEnvelopeIds: seen,
    };
  }
  const latest = preserveNullable(state.latest, incoming);
  const pace = updateRollingPace(state, incoming);
  return {
    ...state,
    connection: incoming.state === 4 ? "ended" : "live",
    latest,
    latestEnvelopeId: incoming.envelopeId,
    route,
    seenEnvelopeIds: seen,
    paceWindow: pace.window,
    rollingPace: pace.value ?? state.rollingPace,
    sampleReceivedAt: now,
    error: undefined,
  };
}

const nullableMetricKeys = [
  "elapsedTimeMilliseconds",
  "distanceDecimeters",
  "speedMillimetersPerSecond",
  "heartRateBPM",
  "altitudeDecimeters",
  "totalAscentMeters",
] as const;

function preserveNullable(previous: Sample | undefined, incoming: Sample): Sample {
  const merged = { ...incoming };
  if (merged.heartRateBPM === 0) merged.heartRateBPM = undefined;
  if (!previous) return merged;
  for (const key of nullableMetricKeys) {
    if (merged[key] === undefined && previous[key] !== undefined) merged[key] = previous[key];
  }
  return merged;
}

function appendRoutePoint(route: RoutePoint[], sample: Sample) {
  if (sample.latitudeMicrodegrees === undefined || sample.longitudeMicrodegrees === undefined)
    return route;
  const point: RoutePoint = {
    envelopeId: sample.envelopeId,
    phoneReceivedAt: sample.phoneReceivedAt,
    latitudeMicrodegrees: sample.latitudeMicrodegrees,
    longitudeMicrodegrees: sample.longitudeMicrodegrees,
    ...(sample.gpsQuality === undefined ? {} : { gpsQuality: sample.gpsQuality }),
  };
  return dedupeRoute([...route, point]);
}

function dedupeRoute(points: RoutePoint[]) {
  const seen = new Set<string>();
  const sorted = points
    .filter((point) => {
      if (seen.has(point.envelopeId)) return false;
      seen.add(point.envelopeId);
      return true;
    })
    .sort(
      (left, right) =>
        left.phoneReceivedAt.localeCompare(right.phoneReceivedAt) ||
        left.envelopeId.localeCompare(right.envelopeId),
    );
  if (sorted.length <= MAX_ROUTE_POINTS) return sorted;
  return [sorted[0]!, ...sorted.slice(-(MAX_ROUTE_POINTS - 1))];
}

function updateRollingPace(state: ActivityState, sample: Sample) {
  if (sample.state !== 1) return { window: state.paceWindow, value: state.rollingPace };
  if (sample.elapsedTimeMilliseconds === undefined || sample.distanceDecimeters === undefined) {
    return { window: state.paceWindow, value: speedPace(sample.speedMillimetersPerSecond) };
  }
  const next = {
    elapsed: sample.elapsedTimeMilliseconds,
    distance: sample.distanceDecimeters,
  };
  const previous = state.paceWindow.at(-1);
  if (previous && (next.elapsed <= previous.elapsed || next.distance < previous.distance)) {
    return { window: state.paceWindow, value: state.rollingPace };
  }
  const window = [...state.paceWindow, next].filter(
    (point) => next.elapsed - point.elapsed <= 30_000,
  );
  const candidates = window.slice(0, -1);
  if (!candidates.some((point) => next.elapsed - point.elapsed >= 8_000)) {
    return { window, value: state.rollingPace };
  }
  const start = candidates.reduce((nearest, point) =>
    Math.abs(next.elapsed - point.elapsed - 10_000) <
    Math.abs(next.elapsed - nearest.elapsed - 10_000)
      ? point
      : nearest,
  );
  const distanceMeters = (next.distance - start.distance) / 10;
  if (distanceMeters < 5) return { window, value: state.rollingPace };
  return {
    window,
    value: validPace((next.elapsed - start.elapsed) / 1000 / distanceMeters),
  };
}

export function bootstrapState(
  snapshot: Snapshot,
  route: FullRoute,
  expiresAt: string,
): ActivityState {
  return activityReducer(initialActivityState, {
    type: "bootstrap",
    session: {
      viewerToken: "redacted",
      expiresAt,
      apiPublicUrl: "http://localhost",
      channelSlug: snapshot.slug,
      mapboxAccessToken: "",
      replayAfterEnvelopeId: null,
      snapshot,
      route,
    },
  });
}
