const request = require('supertest');
const app = require('./app');

describe('GET /', () => {
  it('returns a JSON message with a timestamp', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.body.message).toMatch(/Hello/);
    expect(res.body.timestamp).toBeDefined();
  });
});

describe('GET /health', () => {
  it('returns status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});
