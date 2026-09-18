import type { Pool } from 'pg';

// Both stores initialize on gateway startup. IF NOT EXISTS alone does not
// serialize concurrent extension/table creation on a fresh database.
export async function initializePostgresSchema(pool: Pool, schema: string) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout = '15s'");
    await client.query("SET LOCAL statement_timeout = '60s'");
    await client.query('SELECT pg_advisory_xact_lock(81280, 1)');
    await client.query(schema);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
