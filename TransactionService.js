// ============================================================
// TRANSACTION SERVICE — WITH REDIS CACHING
//
// Cache strategy:
//   READ  operations → check Redis first, fall back to MySQL on miss
//   WRITE operations → write to MySQL, then invalidate (delete) Redis keys
//
// Why invalidate instead of update?
//   When a new expense is added, we don't know what the new "all expenses"
//   list looks like without querying MySQL. So we delete the cached answer.
//   The next GET will query MySQL and cache the fresh result.
//   This is called "cache-aside" or "lazy loading" — the most common strategy.
//
// Cache keys:
//   "all_transactions"       → result of getAllTransactions()
//   "transaction:<id>"       → result of findTransactionById(id)
//
// TTL: 300 seconds (5 minutes).
//   The app shows the same expense list to every user.
//   Stale by up to 5 minutes is acceptable for an expense tracker.
//   After 5 minutes, Redis auto-deletes the key → next request hits MySQL.
// ============================================================

const dbcreds    = require('./DbConfig');
const mysql      = require('mysql2');
const { cacheGet, cacheSet, cacheDel } = require('./RedisClient');

// ── DATABASE CONNECTION ──────────────────────────────────────
// Uses environment variables injected by the Kubernetes ConfigMap,
// falling back to DbConfig.js defaults for local development.
const con = mysql.createConnection({
    host:     process.env.DB_HOST     || dbcreds.DB_HOST,
    user:     process.env.DB_USER     || dbcreds.DB_USER,
    password: process.env.DB_PWD      || dbcreds.DB_PWD,
    database: process.env.DB_DATABASE || dbcreds.DB_DATABASE
});

// ── CACHE KEYS AND TTL ───────────────────────────────────────
const CACHE_TTL          = 300;             // 5 minutes (seconds)
const KEY_ALL            = 'all_transactions';
const keyById = (id) => `transaction:${id}`;


// ── ADD TRANSACTION ─────────────────────────────────────────
// Write path: insert into MySQL, then clear the "all transactions" cache.
// Why clear? The cached list no longer includes the new expense.
// The next GET /transaction will re-query MySQL and cache the fresh list.
function addTransaction(amount, desc) {
    const sql = `INSERT INTO \`transactions\` (\`amount\`, \`description\`) VALUES ('${amount}', '${desc}')`;
    con.query(sql, async function (err, result) {
        if (err) throw err;
        // Invalidate the all-transactions cache so the new expense appears
        // on the next read. No need to invalidate individual-record caches
        // since this is a new record (no existing key for it yet).
        await cacheDel(KEY_ALL);
    });
    return 200;
}


// ── GET ALL TRANSACTIONS ─────────────────────────────────────
// Read path: check Redis first (cache-aside pattern).
//   Cache HIT  → return immediately, 0 DB queries
//   Cache MISS → query MySQL, store in Redis, return result
function getAllTransactions(callback) {
    // Step 1: check the cache
    cacheGet(KEY_ALL).then(async (cached) => {
        if (cached !== null) {
            // Cache HIT — serve the answer from Redis instantly
            console.log(`{"msg":"cache hit","key":"${KEY_ALL}"}`);
            return callback(cached);
        }

        // Cache MISS — query MySQL
        console.log(`{"msg":"cache miss","key":"${KEY_ALL}","source":"mysql"}`);
        con.query('SELECT * FROM transactions', async function (err, result) {
            if (err) throw err;

            // Store in Redis for the next 5 minutes
            await cacheSet(KEY_ALL, result, CACHE_TTL);

            return callback(result);
        });
    }).catch((err) => {
        // Redis completely unavailable — fall through to MySQL
        console.error(`{"msg":"Redis unavailable, querying MySQL","error":"${err.message}"}`);
        con.query('SELECT * FROM transactions', function (err, result) {
            if (err) throw err;
            return callback(result);
        });
    });
}


// ── FIND TRANSACTION BY ID ───────────────────────────────────
// Same cache-aside pattern but keyed per record.
function findTransactionById(id, callback) {
    const cacheKey = keyById(id);

    cacheGet(cacheKey).then(async (cached) => {
        if (cached !== null) {
            console.log(`{"msg":"cache hit","key":"${cacheKey}"}`);
            return callback(cached);
        }

        console.log(`{"msg":"cache miss","key":"${cacheKey}","source":"mysql"}`);
        con.query(`SELECT * FROM transactions WHERE id = ${id}`, async function (err, result) {
            if (err) throw err;
            await cacheSet(cacheKey, result, CACHE_TTL);
            return callback(result);
        });
    }).catch((err) => {
        console.error(`{"msg":"Redis unavailable, querying MySQL","error":"${err.message}"}`);
        con.query(`SELECT * FROM transactions WHERE id = ${id}`, function (err, result) {
            if (err) throw err;
            return callback(result);
        });
    });
}


// ── DELETE ALL TRANSACTIONS ──────────────────────────────────
// Write path: delete from MySQL, clear cache.
// We can't know which individual-record keys exist in Redis,
// so we clear the all-transactions key at minimum.
// Individual keys will naturally expire after their TTL anyway.
function deleteAllTransactions(callback) {
    con.query('DELETE FROM transactions', async function (err, result) {
        if (err) throw err;
        // Clear the all-transactions cache — data is gone from MySQL
        await cacheDel(KEY_ALL);
        return callback(result);
    });
}


// ── DELETE TRANSACTION BY ID ─────────────────────────────────
// Write path: delete from MySQL, clear both the individual key
// and the all-transactions key (the list no longer includes this record).
function deleteTransactionById(id, callback) {
    con.query(`DELETE FROM transactions WHERE id = ${id}`, async function (err, result) {
        if (err) throw err;
        // Invalidate the specific record key AND the all-transactions list
        await cacheDel(keyById(id), KEY_ALL);
        return callback(result);
    });
}


module.exports = {
    addTransaction,
    getAllTransactions,
    findTransactionById,
    deleteAllTransactions,
    deleteTransactionById
};
