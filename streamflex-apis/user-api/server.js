const express = require('express');
const mysql = require('mysql2/promise');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');

const app = express();
const PORT = process.env.PORT || 5000;

const dbConfig = {
  host: process.env.RDS_HOST || 'localhost',
  port: parseInt(process.env.RDS_PORT || '3306'),
  user: process.env.RDS_USER || 'admin',
  password: process.env.RDS_PASSWORD || '',
  database: process.env.RDS_DB || 'streamflex',
  waitForConnections: true,
  connectionLimit: 10,
};

const REPLICATION_REGION = process.env.REPLICATION_REGION || 'us-west-2';
const REPLICATION_FUNCTION_NAME = process.env.REPLICATION_LAMBDA_NAME || 'streamflex-user-replication';

const lambdaClient = new LambdaClient({ region: REPLICATION_REGION });

let pool;

async function initDb() {
  const dbName = process.env.RDS_DB || 'streamflex';

  const tmpConn = await mysql.createConnection({
    host: process.env.RDS_HOST || 'localhost',
    port: parseInt(process.env.RDS_PORT || '3306'),
    user: process.env.RDS_USER || 'admin',
    password: process.env.RDS_PASSWORD || '',
  });
  await tmpConn.execute(`CREATE DATABASE IF NOT EXISTS \`${dbName}\``);
  await tmpConn.end();

  pool = mysql.createPool(dbConfig);
  const conn = await pool.getConnection();
  await conn.execute(`
    CREATE TABLE IF NOT EXISTS users (
      userId VARCHAR(255) PRIMARY KEY,
      username VARCHAR(255) NOT NULL,
      plan VARCHAR(50) DEFAULT 'free',
      createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  conn.release();
  console.log('Database initialized');

  if (REPLICATION_REGION) {
    console.log(`Replication configured via Lambda ${REPLICATION_FUNCTION_NAME} in ${REPLICATION_REGION}`);
  }
}

async function replicateToWest(action, params) {
  if (!REPLICATION_REGION) return;
  try {
    const payload = JSON.stringify({ action, params });
    const command = new InvokeCommand({
      FunctionName: REPLICATION_FUNCTION_NAME,
      InvocationType: 'Event',
      Payload: Buffer.from(payload),
    });
    await lambdaClient.send(command);
  } catch (err) {
    console.error('Failed to replicate to west Lambda:', err.message);
  }
}

app.use(express.json());
app.use((_req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

app.options('*', (_req, res) => {
  res.sendStatus(204);
});

app.get('/user/health', async (_req, res) => {
  try {
    const conn = await pool.getConnection();
    await conn.execute('SELECT 1');
    conn.release();
    res.status(200).json({
      status: 'ok',
      service: 'user',
      database: 'aurora-mysql',
      replication: REPLICATION_REGION ? 'lambda-configured' : 'disabled',
    });
  } catch (error) {
    res.status(503).json({ status: 'error', service: 'user', message: error.message });
  }
});

app.get('/health', async (_req, res) => {
  try {
    const conn = await pool.getConnection();
    await conn.execute('SELECT 1');
    conn.release();
    res.status(200).json({
      status: 'ok',
      service: 'user',
      database: 'aurora-mysql',
      replication: REPLICATION_REGION ? 'lambda-configured' : 'disabled',
    });
  } catch (error) {
    res.status(503).json({ status: 'error', service: 'user', message: error.message });
  }
});

app.get('/user', async (_req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM users');
    res.status(200).json({
      service: 'user',
      message: 'StreamFlex user API from Aurora MySQL',
      count: rows.length,
      profiles: rows,
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({ error: 'Failed to fetch users', service: 'user' });
  }
});

app.get('/user/:id', async (req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM users WHERE userId = ?', [req.params.id]);
    if (rows.length === 0) {
      return res.status(404).json({ error: 'User not found', service: 'user' });
    }
    res.status(200).json(rows[0]);
  } catch (error) {
    console.error('Error fetching user:', error);
    res.status(500).json({ error: 'Failed to fetch user', service: 'user' });
  }
});

app.post('/user', async (req, res) => {
  try {
    const { userId, username, plan } = req.body;
    if (!userId || !username) {
      return res.status(400).json({ error: 'Missing userId or username', service: 'user' });
    }
    const user = { userId, username, plan: plan || 'free', createdAt: new Date() };
    await pool.execute(
      'INSERT INTO users (userId, username, plan, createdAt) VALUES (?, ?, ?, ?)',
      [user.userId, user.username, user.plan, user.createdAt]
    );
    replicateToWest('INSERT', [user.userId, user.username, user.plan, user.createdAt.toISOString().slice(0, 19).replace('T', ' ')]);
    res.status(201).json({ message: 'User created', user, replication: REPLICATION_REGION ? 'lambda' : 'local-only' });
  } catch (error) {
    console.error('Error creating user:', error);
    if (error.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ error: 'User already exists', service: 'user' });
    }
    res.status(500).json({ error: 'Failed to create user', service: 'user' });
  }
});

app.delete('/user/:id', async (req, res) => {
  try {
    const [result] = await pool.execute('DELETE FROM users WHERE userId = ?', [req.params.id]);
    if (result.affectedRows === 0) {
      return res.status(404).json({ error: 'User not found', service: 'user' });
    }
    replicateToWest('DELETE', [req.params.id]);
    res.status(200).json({ message: 'User deleted', userId: req.params.id });
  } catch (error) {
    console.error('Error deleting user:', error);
    res.status(500).json({ error: 'Failed to delete user', service: 'user' });
  }
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found', service: 'user' });
});

initDb().then(() => {
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`User API listening on port ${PORT}`);
    console.log(`Connected to Aurora MySQL at ${dbConfig.host}:${dbConfig.port}/${dbConfig.database}`);
    if (REPLICATION_REGION) {
      console.log(`Replication via Lambda ${REPLICATION_FUNCTION_NAME} in ${REPLICATION_REGION}`);
    }
  });
}).catch((err) => {
  console.error('Failed to initialize database:', err);
  process.exit(1);
});
