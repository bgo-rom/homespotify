import { loadConfig } from '../config.js';
import { createDb } from './client.js';
import { runMigrations } from './migrate.js';

const config = loadConfig();
const handle = createDb(config.dbPath);
try {
  runMigrations(handle);
  console.log(`Migrations appliquées sur ${config.dbPath}`);
} finally {
  handle.sqlite.close();
}
