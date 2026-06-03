const express = require('express');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const {
  DynamoDBDocumentClient,
  ScanCommand,
  PutCommand,
  GetCommand,
  DeleteCommand
} = require('@aws-sdk/lib-dynamodb');
const app = express();
const PORT = process.env.PORT || 8080;
const TABLE_NAME = process.env.DYNAMODB_TABLE || 'streamflex-catalog-db';
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';

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

// Initialiser DynamoDB Document Client
const client = new DynamoDBClient({ region: AWS_REGION });
const dynamoDb = DynamoDBDocumentClient.from(client);

app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', service: 'catalog' });
});

// GET /catalog - Liste tous les vidéos
app.get('/catalog', async (_req, res) => {
  try {
    const command = new ScanCommand({ TableName: TABLE_NAME });
    const result = await dynamoDb.send(command);
    const videos = result.Items || [];
    
    res.status(200).json({
      service: 'catalog',
      message: 'StreamFlex catalog API from DynamoDB',
      count: videos.length,
      videos
    });
  } catch (error) {
    console.error('Error fetching catalog:', error);
    res.status(500).json({ error: 'Failed to fetch catalog', service: 'catalog' });
  }
});

// GET /catalog/:id - Récupérer une vidéo spécifique
app.get('/catalog/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const command = new GetCommand({ TableName: TABLE_NAME, Key: { id } });
    const result = await dynamoDb.send(command);
    
    if (!result.Item) {
      return res.status(404).json({ error: 'Video not found', service: 'catalog' });
    }
    
    res.status(200).json(result.Item);
  } catch (error) {
    console.error('Error fetching video:', error);
    res.status(500).json({ error: 'Failed to fetch video', service: 'catalog' });
  }
});

// POST /catalog - Ajouter une vidéo
app.post('/catalog', async (req, res) => {
  try {
    const { id, title, category } = req.body;
    
    if (!id || !title) {
      return res.status(400).json({ error: 'Missing id or title', service: 'catalog' });
    }
    
    const video = {
      id,
      title,
      category: category || 'Unknown',
      createdAt: new Date().toISOString()
    };
    
    const command = new PutCommand({ TableName: TABLE_NAME, Item: video });
    await dynamoDb.send(command);
    
    res.status(201).json({ message: 'Video created', video });
  } catch (error) {
    console.error('Error creating video:', error);
    res.status(500).json({ error: 'Failed to create video', service: 'catalog' });
  }
});

// DELETE /catalog/:id - Supprimer une vidéo
app.delete('/catalog/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const command = new DeleteCommand({ TableName: TABLE_NAME, Key: { id } });
    await dynamoDb.send(command);
    
    res.status(200).json({ message: 'Video deleted', id });
  } catch (error) {
    console.error('Error deleting video:', error);
    res.status(500).json({ error: 'Failed to delete video', service: 'catalog' });
  }
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found', service: 'catalog' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Catalog API listening on port ${PORT}`);
  console.log(`Connected to DynamoDB table: ${TABLE_NAME} in region ${AWS_REGION}`);
});
