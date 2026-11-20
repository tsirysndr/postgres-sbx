import { async } from '../Bsdkrun.Internal/foreign.js';

export const queryImpl = spec => async(signal => new Promise((resolve, reject) => {
  let close = () => {};
  const cancel = () => { close(); reject(Error('Database query interrupted')); };
  const timer = setTimeout(() => { close(); reject(Error('Database query timed out')); }, 45000);
  signal.addEventListener('abort', cancel, { once: true });
  (async () => {
    const { Client } = await import('pg');
    const client = new Client({ connectionString: spec.url, connectionTimeoutMillis: 10000, query_timeout: 30000 });
    close = () => client.end();
    try { await client.connect(); const result = await client.query(spec.sql); return result.rows.map(row => Object.values(row).map(String)); }
    finally { await client.end(); }
  })().then(resolve, reject).finally(() => { clearTimeout(timer); signal.removeEventListener('abort', cancel); });
}));
