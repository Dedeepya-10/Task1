const express = require('express');

const app = express();

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from the containerized DevOps task app!',
    hostname: require('os').hostname(),
    timestamp: new Date().toISOString(),
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

module.exports = app;
