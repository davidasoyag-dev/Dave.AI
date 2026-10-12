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
const DAILY_INVITE_CAP = 10;

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

  // Per-user cap: max DAILY_INVITE_CAP invites per user per UTC day (counted with the service key)
  const svcHeaders = {
    'apikey': SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SERVICE_ROLE_KEY
  };
  const dayStart = new Date();
  dayStart.setUTCHours(0, 0, 0, 0);
  const countPath = '/rest/v1/team_invites?select=id' +
    '&inviter_id=eq.' + encodeURIComponent(user.id) +
    '&created_at=gte.' + encodeURIComponent(dayStart.toISOString());
  const countRes = await request('GET', SUPABASE_HOST, countPath, svcHeaders);
  if (countRes.status !== 200 || !Array.isArray(countRes.json)) {
    return { statusCode: 500, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ error: 'Could not send the invite. Please try again.' }) };
  }
  if (countRes.json.length >= DAILY_INVITE_CAP) {
    return { statusCode: 429, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ error: 'Daily invite limit reached. Please try again tomorrow.' }) };
  }

  const body = JSON.stringify({
    email: invitedEmail,
    data: { invited_by_email: user.email, invited_by_firm: (user.user_metadata && user.user_metadata.firm) || '' },
    redirect_to: 'https://daveai.law/login.html'
  });

  const res = await request('POST', SUPABASE_HOST, '/auth/v1/invite', {
    'Content-Type': 'application/json',
    'apikey': SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SERVICE_ROLE_KEY,
    'Content-Length': Buffer.byteLength(body)
  }, body);

  if (res.status === 200 || res.status === 201) {
    // Record the invite server-side so the daily cap can't be bypassed
    const row = JSON.stringify({ inviter_id: user.id, invited_email: invitedEmail });
    const ins = await request('POST', SUPABASE_HOST, '/rest/v1/team_invites', {
      ...svcHeaders,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal',
      'Content-Length': Buffer.byteLength(row)
    }, row);
    if (ins.status < 200 || ins.status >= 300) {
      console.error('team_invites insert failed', ins.status);
    }
    return { statusCode: 200, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ ok: true }) };
  }

  // Supabase returns 422 when the email is already registered/invited
  const msg = (res.json && (res.json.msg || res.json.message)) || '';
  const friendly = /already|exists|registered/i.test(msg)
    ? 'That email is already registered with Dave.AI.'
    : 'Could not send the invite. Please try again.';
  return { statusCode: res.status >= 400 ? res.status : 500, headers: { 'Content-Type': 'application/json', ...cors }, body: JSON.stringify({ error: friendly }) };
};
