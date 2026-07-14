const attempts = new Map<string, { count: number; resetAt: number }>();

export function allowSession(ip: string, now = Date.now()) {
  const current = attempts.get(ip);
  if (!current || current.resetAt <= now) {
    attempts.set(ip, { count: 1, resetAt: now + 60_000 });
    return true;
  }
  if (current.count >= 20) return false;
  current.count += 1;
  if (attempts.size > 1000) {
    for (const [key, value] of attempts) if (value.resetAt <= now) attempts.delete(key);
  }
  return true;
}

export function requestIP(request: Request) {
  return (
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown"
  );
}

export function isSameOrigin(request: Request) {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite && fetchSite !== "same-origin") return false;
  const origin = request.headers.get("origin");
  if (!origin) return true;

  const internalUrl = new URL(request.url);
  const protocol =
    firstForwarded(request, "x-forwarded-proto") ?? internalUrl.protocol.slice(0, -1);
  const host =
    firstForwarded(request, "x-forwarded-host") ?? request.headers.get("host") ?? internalUrl.host;
  try {
    return new URL(origin).origin === new URL(`${protocol}://${host}`).origin;
  } catch {
    return false;
  }
}

function firstForwarded(request: Request, name: string) {
  return request.headers.get(name)?.split(",")[0]?.trim() || undefined;
}
