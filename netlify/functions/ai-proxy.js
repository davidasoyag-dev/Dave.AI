const https = require('https');

const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY;
const BRAVE_KEY = process.env.BRAVE_SEARCH_KEY;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const SUPABASE_HOST = 'wyribnzwosqzfnhomhig.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind5cmlibnp3b3NxemZuaG9taGlnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzUyNTAsImV4cCI6MjA5NDcxMTI1MH0.obrpUEG6mRHdugLeznOrFcC6GalW7wJvgAzhaBSneWo';

// Make a GET request and return { status, json }
function getJson(hostname, path, headers) {
  return new Promise((resolve) => {
    const req = https.request({ hostname, path, method: 'GET', headers }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (e) {}
        resolve({ status: res.statusCode, json });
      });
    });
    req.on('error', () => resolve({ status: 0, json: null }));
    req.end();
  });
}

// Verify the caller's Supabase login token; returns the user or null
async function verifyUser(event) {
  const h = event.headers || {};
  const auth = h.authorization || h.Authorization || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  const res = await getJson(SUPABASE_HOST, '/auth/v1/user', {
    'Authorization': 'Bearer ' + token,
    'apikey': SUPABASE_ANON
  });
  return (res && res.status === 200 && res.json && res.json.id) ? res.json : null;
}

// Search Brave for recent UK law results
async function braveSearch(query) {
  const path = '/res/v1/web/search?q=' + encodeURIComponent(query + ' UK law legislation 2024 2025') + '&count=5&country=gb&search_lang=en';
  const res = await getJson('api.search.brave.com', path, {
    'Accept': 'application/json',
    'Accept-Encoding': 'gzip',
    'X-Subscription-Token': BRAVE_KEY
  });
  const result = res && res.json;

  if (!result || !result.web || !result.web.results) return '';

  const snippets = result.web.results.slice(0, 5).map((r, i) =>
    `[${i + 1}] ${r.title}\n${r.description || ''}\nSource: ${r.url}`
  ).join('\n\n');

  return snippets;
}

// Call Anthropic API
function callAnthropic(body) {
  return new Promise((resolve) => {
    const req = https.request({
      hostname: 'api.anthropic.com',
      path: '/v1/messages',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01',
        'Content-Length': Buffer.byteLength(body)
      }
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on('error', (e) => resolve({ statusCode: 500, body: JSON.stringify({ error: e.message }) }));
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers: cors, body: '' };
  }

  let payload;
  try {
    payload = JSON.parse(event.body);
  } catch (e) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  // If web_search is requested, fetch live results and inject into system prompt
  if (payload.web_search && payload.messages && payload.messages.length > 0) {
    const userQuery = payload.messages[payload.messages.length - 1].content;
    try {
      const searchResults = await braveSearch(userQuery);
      if (searchResults) {
        payload.system = (payload.system || '') +
          '\n\n--- LIVE WEB SEARCH RESULTS (use these to inform your answer with up-to-date information) ---\n' +
          searchResults +
          '\n--- END OF SEARCH RESULTS ---\n' +
          'Where relevant, reference the above search results to ensure your answer reflects the latest UK legislation and case law. Always note if a law has recently changed.';
      }
    } catch (e) {
      // Search failed — continue without it
    }
    delete payload.web_search;
  }

  const body = JSON.stringify(payload);
  const result = await callAnthropic(body);

  return {
    statusCode: result.statusCode,
    headers: { 'Content-Type': 'application/json', ...cors },
    body: result.body
  };
};
