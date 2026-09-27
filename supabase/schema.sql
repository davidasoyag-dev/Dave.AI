const https = require('https');

const SUPABASE_HOST = 'wyribnzwosqzfnhomhig.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIs' +
  'InR5cCI6IkpXVCJ9.eyJ' +
  'pc3MiOiJzdXBhYmFzZSI' +
  'sInJlZiI6Ind5cmlibnp' +
  '3b3NxemZuaG9taGlnIiw' +
  'icm9sZSI6ImFub24iLCJ' +
  'pYXQiOjE3NzkxMzUyNTA' +
  'sImV4cCI6MjA5NDcxMTI' +
  '1MH0.obrpUEG6mRHdugL' +
  'eznOrFcC6GalW7wJvgAz' +
  'haBSneWo';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function request(method, hostname, path, headers, body) {
  return new Promise((resolve) => {
    const req = https.request({ hostname, path, method, headers }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (e) {}
        resolve({ status: res.statusCode, json });
      });
    });
    req.on('error', () => resolve({ status: 0, json: null }));
    if (body) req.write(body);
    req.end();
  });
}

// Verify the caller's Supabase login token; returns the user or null
async function verifyUser(event) {
  const h = event.headers || {};
  const auth = h.authorization || h.Authorization || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  const res = await request('GET', SUPABASE_HOST, '/auth/v1/user', {
    'Authorization': 'Bearer ' + token,
    'apikey': SUPABASE_ANON
  });
  return (res && res.status === 200 && res.json && res.json.id) ? res.json : null;
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers: cors, body: '' };
  }
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: cors, body: 'Method Not Allowed' };
  }
  if (!SERVICE_ROLE_KEY) {
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: 'Server not configured for invites yet.' }) };
  }

  // Require a valid logged-in Dave.AI user — only a real, signed-in user can invite someone
  const user = await verifyUser(event);
  if (!user) {
    return { statusCode: 401, headers: cors, body: JSON.stringify({ error: 'Please sign in to invite a team member.' }) };
  }

  let payload;
  try {
    payload = JSON.parse(event.body);
  } catch (e) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'Invalid request.' }) };
  }

  const invitedEmail = (payload.email || '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(invitedEmail)) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'Please enter a valid email address.' }) };
  }

  const origin = (event.headers.origin || 'https://daveai.law').replace(/\/$/, '');
  const body = JSON.stringify({
    email: invitedEmail,
    data: { invited_by_email: user.email, invited_by_firm: (user.user_metadata && user.user_metadata.firm) || '' },
    redirect_to: origin + '/login.html'
  });

  const res = await request('POST', SUPABASE_HOST, '/auth/v1/invite', {
    'Content-Type': 'application/json',
    'apikey': SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SERVICE_ROLE_KEY,
    'Content-Length': Buffer.byteLength(body)
  }, body);

  if (res.status === 200 || res.status === 201) {
    return { statusCode: 200, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ ok: true }) };
  }

  // Supabase returns 422 when the email is already registered/invited
  const msg = (res.json && (res.json.msg || res.json.message)) || '';
  const friendly = /already|exists|registered/i.test(msg)
    ? 'That email is already registered with Dave.AI.'
    : 'Could not send the invite. Please try again.';
  return { statusCode: res.status >= 400 ? res.status : 500, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ error: friendly }) };
};
