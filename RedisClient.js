// ============================================================
// REDIS CLIENT — CONNECTION MANAGER
//
// What this file does:
//   Creates and exports a single Redis connection that the whole
//   app shares. Like having one phone line to the post office —
//   you don't open a new line for every letter you send.
//
// Why ioredis?
//   ioredis is the most popular Node.js Redis client.
//   It handles reconnection automatically (if Redis restarts,
//   the app reconnects without crashing), has a Promise-based API,
//   and supports all Redis commands.
//
// Environment variables:
//   REDIS_HOST — set by Kubernetes ConfigMap (the ElastiCache endpoint)
//   REDIS_PORT — default 6379 (Redis standard port)
//
// Fail-safe design:
//   If Redis is not configured (no REDIS_HOST), or if the connection
//   fails, the app still works — it just falls back to querying MySQL
//   every time. The cache is an optimisation, not a hard dependency.
// ============================================================

const Redis = require('ioredis');

// If no Redis host is configured, skip Redis entirely.
// This lets the app run locally during development without Redis.
const REDIS_HOST = process.env.REDIS_HOST;
const REDIS_PORT = parseInt(process.env.REDIS_PORT || '6379', 10);

let client = null;

if (REDIS_HOST) {
    client = new Redis({
        host: REDIS_HOST,
        port: REDIS_PORT,

        // Retry logic: if Redis goes down temporarily, keep trying.
        // Stops after 10 failed attempts to avoid infinite retry loops.
        // lazyConnect: true means we don't connect until the first command.
        lazyConnect: false,
        maxRetriesPerRequest: 3,

        // If all retry attempts fail, log the error but don't crash the app.
        // The app falls back to querying MySQL directly.
        retryStrategy(times) {
            if (times > 10) {
                console.error('{"msg":"Redis connection failed after 10 retries — falling back to direct DB queries"}');
                return null; // stop retrying
            }
            // Wait 200ms, 400ms, 600ms... between retries (exponential-ish backoff)
            return Math.min(times * 200, 2000);
        },
    });

    client.on('connect', () => {
        console.log(`{"msg":"Redis connected","host":"${REDIS_HOST}","port":${REDIS_PORT}}`);
    });

    client.on('error', (err) => {
        // Log but don't crash — the cache being down is not fatal
        console.error(`{"msg":"Redis error","error":"${err.message}"}`);
    });

    client.on('reconnecting', () => {
        console.warn('{"msg":"Redis reconnecting..."}');
    });
} else {
    console.warn('{"msg":"REDIS_HOST not set — Redis caching disabled, all queries go to MySQL"}');
}

// ── CACHE HELPER FUNCTIONS ─────────────────────────────────

/**
 * Get a value from Redis.
 * Returns null if: key doesn't exist, Redis is down, or Redis is not configured.
 * The caller treats null as a "cache miss" and queries MySQL instead.
 */
async function cacheGet(key) {
    if (!client) return null;
    try {
        const value = await client.get(key);
        return value ? JSON.parse(value) : null;
    } catch (err) {
        // Redis error = cache miss, not a fatal error
        console.error(`{"msg":"Redis GET failed","key":"${key}","error":"${err.message}"}`);
        return null;
    }
}

/**
 * Store a value in Redis with a TTL (time-to-live in seconds).
 * After TTL seconds, Redis automatically deletes the key.
 * Silently fails if Redis is down — the app continues normally.
 */
async function cacheSet(key, value, ttlSeconds) {
    if (!client) return;
    try {
        // EX = expire in N seconds. After TTL, the key is automatically deleted.
        await client.set(key, JSON.stringify(value), 'EX', ttlSeconds);
    } catch (err) {
        console.error(`{"msg":"Redis SET failed","key":"${key}","error":"${err.message}"}`);
    }
}

/**
 * Delete one or more keys from Redis.
 * Called after writes (POST, DELETE) so the next read fetches fresh data.
 * Known as "cache invalidation" — clearing stale answers from the sticky note.
 */
async function cacheDel(...keys) {
    if (!client) return;
    try {
        await client.del(...keys);
    } catch (err) {
        console.error(`{"msg":"Redis DEL failed","keys":"${keys.join(',')}","error":"${err.message}"}`);
    }
}

module.exports = { cacheGet, cacheSet, cacheDel };
