const express = require('express');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, scan, put, get, delete: deleteItem } = require('@aws-sdk/lib-dynamodb');
const app = express();
const PORT = process.env.PORT || 5000;
const TABLE_NAME = process.env.DYNAMODB_TABLE || 'streamflex-user-db';
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';

app.use(express.json());

// Initialiser DynamoDB Document Client
const client = new DynamoDBClient({ region: AWS_REGION });
const dynamoDb = DynamoDBDocumentClient.from(client);

app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', service: 'user' });
});

// GET /user - Liste tous les utilisateurs
app.get('/user', async (_req, res) => {
  try {
    const command = scan({ TableName: TABLE_NAME });
    const result = await dynamoDb.send(command);
    
    res.status(200).json({
      service: 'user',
      message: 'StreamFlex user API from DynamoDB',
      count: result.Items.length,
      profiles: result.Items || []
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({ error: 'Failed to fetch users', service: 'user' });
  }
});

// GET /user/:id - Récupérer un utilisateur spécifique
app.get('/user/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const command = get({ TableName: TABLE_NAME, Key: { userId: id } });
    const result = await dynamoDb.send(command);
    
    if (!result.Item) {
      return res.status(404).json({ error: 'User not found', service: 'user' });
    }
    
    res.status(200).json(result.Item);
  } catch (error) {
    console.error('Error fetching user:', error);
    res.status(500).json({ error: 'Failed to fetch user', service: 'user' });
  }
});

// POST /user - Créer un utilisateur
app.post('/user', async (req, res) => {
  try {
    const { userId, username, plan } = req.body;
    
    if (!userId || !username) {
      return res.status(400).json({ error: 'Missing userId or username', service: 'user' });
    }
    
    const user = {
      userId,
      username,
      plan: plan || 'free',
      createdAt: new Date().toISOString()
    };
    
    const command = put({ TableName: TABLE_NAME, Item: user });
    await dynamoDb.send(command);
    
    res.status(201).json({ message: 'User created', user });
  } catch (error) {
    console.error('Error creating user:', error);
    res.status(500).json({ error: 'Failed to create user', service: 'user' });
  }
});

// DELETE /user/:id - Supprimer un utilisateur
app.delete('/user/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const command = deleteItem({ TableName: TABLE_NAME, Key: { userId: id } });
    await dynamoDb.send(command);
    
    res.status(200).json({ message: 'User deleted', userId: id });
  } catch (error) {
    console.error('Error deleting user:', error);
    res.status(500).json({ error: 'Failed to delete user', service: 'user' });
  }
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found', service: 'user' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`User API listening on port ${PORT}`);
  console.log(`Connected to DynamoDB table: ${TABLE_NAME} in region ${AWS_REGION}`);
});
