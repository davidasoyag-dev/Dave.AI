const https = require('https');
const querystring = require('querystring');

const STRIPE_SECRET = process.env.STRIPE_SECRET_KEY;

function stripeRequest(method, path, body) {
  return new Promise((resolve) => {
    const data = body ? querystring.stringify(body) : null;
    const req = https.request({
      hostname: 'api.stripe.com',
      path: path,
      method: method,
      headers: {
        'Authorization': `Bearer ${STRIPE_SECRET}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {})
      }
    }, (res) => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(d) }); }
        catch (e) { resolve({ status: res.statusCode, data: d }); }
      });
    });
    req.on('error', e => resolve({ status: 500, data: { error: e.message } }));
    if (data) req.write(data);
    req.end();
  });
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers: cors, body: '' };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: cors, body: 'Method Not Allowed' };
  }

  let email;
  try {
    email = JSON.parse(event.body).email;
  } catch (e) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'Invalid request' }) };
  }

  if (!email) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'Email required' }) };
  }

  // Find Stripe customer by email
  const searchRes = await stripeRequest('GET', `/v1/customers?email=${encodeURIComponent(email)}&limit=1`, null);

  if (searchRes.status !== 200 || !searchRes.data.data || searchRes.data.data.length === 0) {
    return {
      statusCode: 404,
      headers: cors,
      body: JSON.stringify({ error: 'No billing account found for this email. Please contact support@daveai.law.' })
    };
  }

  const customerId = searchRes.data.data[0].id;

  // Get return URL from request origin
  const origin = (event.headers.origin || 'https://daveai.law').replace(/\/$/, '');

  // Create billing portal session
  const portalRes = await stripeRequest('POST', '/v1/billing_portal/sessions', {
    customer: customerId,
    return_url: `${origin}/dashboard.html`
  });

  if (portalRes.status !== 200) {
    return {
      statusCode: 500,
      headers: cors,
      body: JSON.stringify({ error: 'Could not create billing session. Please try again.' })
    };
  }

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', ...cors },
    body: JSON.stringify({ url: portalRes.data.url })
  };
};
