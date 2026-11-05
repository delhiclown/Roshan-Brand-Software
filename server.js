require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const publicDirectory = path.join(__dirname, 'public');

app.get('/api/config', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    supabaseUrl: process.env.SUPABASE_URL || '',
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY || ''
  });
});

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
