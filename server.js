require('dotenv').config({ path: '.env.local' });
require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const publicDirectory = path.join(__dirname, 'public');

app.use(express.json({ limit: '16kb' }));

app.get('/api/config', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    supabaseUrl: process.env.SUPABASE_URL || '',
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY || ''
  });
});

app.post('/api/guest-checkout', (req, res) => require('./api/guest-checkout')(req, res));
app.post('/api/guest-order-email', (req, res) => require('./api/guest-order-email')(req, res));
app.post('/api/notify-order', (req, res) => require('./api/notify-order')(req, res));
app.all('/api/channel-stats', (req, res) => require('./api/channel-stats')(req, res));

app.get('/admin', (req, res) => {
  res.sendFile(path.join(publicDirectory, 'admin.html'));
});

app.use(express.static(publicDirectory));

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`Store running on http://localhost:${port}`);
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_ANON_KEY) {
    console.warn('Set SUPABASE_URL and SUPABASE_ANON_KEY to connect the store.');
  }
});
