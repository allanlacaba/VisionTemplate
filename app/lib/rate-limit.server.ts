type RateLimitEntry = { count: number; windowStart: number };

type GlobalWithRateLimit = typeof globalThis & {
  __noteRateLimit?: Map<string, RateLimitEntry>;
};

function getStore(): Map<string, RateLimitEntry> {
  const g = globalThis as GlobalWithRateLimit;
  if (!g.__noteRateLimit) {
    g.__noteRateLimit = new Map();
  }
  return g.__noteRateLimit;
}

export function getClientIp(request: Request): string {
  const forwardedFor = request.headers.get("x-forwarded-for");
  if (forwardedFor) {
    const first = forwardedFor.split(",")[0]?.trim();
    if (first) return first;
  }
  const realIp = request.headers.get("x-real-ip");
  if (realIp) return realIp.trim();
  return "unknown";
}

export type RateLimitResult = {
  allowed: boolean;
  remaining: number;
  retryAfterSec: number;
};

export function checkRateLimit(
  key: string,
  opts: { limit: number; windowMs: number },
): RateLimitResult {
  const { limit, windowMs } = opts;
  const store = getStore();
  const now = Date.now();

  let entry = store.get(key);
  if (!entry || now - entry.windowStart >= windowMs) {
    entry = { count: 0, windowStart: now };
    store.set(key, entry);
  }

  entry.count += 1;
  const allowed = entry.count <= limit;

  // Opportunistic prune of expired entries (best-effort, keeps the map tidy).
  if (store.size > 1000) {
    for (const [k, e] of store) {
      if (now - e.windowStart >= windowMs) store.delete(k);
    }
  }

  const remaining = Math.max(0, limit - entry.count);
  const retryAfterSec = Math.max(
    0,
    Math.ceil((entry.windowStart + windowMs - now) / 1000),
  );

  return { allowed, remaining, retryAfterSec };
}
