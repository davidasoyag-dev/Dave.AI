const https = require('https');
const crypto = require('crypto');

const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;
const SUPABASE_URL = 'https://wyribnzwosqzfnhomhig.supabase.co';
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

// Verify Stripe webhook signature
function verifyStripeSignature(payload, sigHeader, secret) {
  if (!secret) return true; // skip verification if secret not set yet
  if (!sigHeader) return false; // secret is configured — a missing header is a forgery attempt, not a pass
  try {
    const parts = sigHeader.split(',').reduce((acc, part) => {
      const [k, v] = part.split('=');
      acc[k] = v;
      return acc;
    }, {});
    const timestamp = parts['t'];
    const sig = parts['v1'];
    const signed = `${timestamp}.${payload}`;
    const expected = crypto.createHmac('sha256', secret).update(signed).digest('hex');
    return crypto.timingSafeEqual(Buffer.from(sig, 'hex'), Buffer.from(expected, 'hex'));
  } catch (e) {
    return false;
  }
}

// Call Supabase Admin API
function supabaseRequest(method, path, body) {
  return new Promise((resolve) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request({
      hostname: 'wyribnzwosqzfnhomhig.supabase.co',
      path: path,
      method: method,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${SUPABASE_SERVICE_KEY}`,
        'apikey': SUPABASE_SERVICE_KEY,
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

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  const sig = event.headers['stripe-signature'];
  const payload = event.body;

  // Verify signature
  if (STRIPE_WEBHOOK_SECRET && !verifyStripeSignature(payload, sig, STRIPE_WEBHOOK_SECRET)) {
    console.error('Stripe signature verification failed');
    return { statusCode: 400, body: 'Invalid signature' };
  }

  let stripeEvent;
  try {
    stripeEvent = JSON.parse(payload);
  } catch (e) {
    return { statusCode: 400, body: 'Invalid JSON' };
  }

  console.log('Stripe event:', stripeEvent.type);

  // Handle checkout completed
  if (stripeEvent.type === 'checkout.session.completed') {
    const session = stripeEvent.data.object;
    const email = session.customer_details && session.customer_details.email;
    const planId = session.metadata && session.metadata.plan;

    if (!email) {
      console.error('No email in session');
      return { statusCode: 200, body: 'OK - no email' };
    }

    console.log('Activating plan for:', email);

    // Find user by email in Supabase
    const listRes = await supabaseRequest('GET', `/auth/v1/admin/users?email=${encodeURIComponent(email)}&per_page=1`, null);

    if (listRes.status !== 200 || !listRes.data.users || listRes.data.users.length === 0) {
      console.error('User not found:', email, listRes);
      return { statusCode: 200, body: 'OK - user not found' };
    }

    const user = listRes.data.users[0];
    const existingMeta = user.user_metadata || {};

    // Update user metadata to activate plan
    const updateRes = await supabaseRequest('PUT', `/auth/v1/admin/users/${user.id}`, {
      user_metadata: {
        ...existingMeta,
        planActive: true,
        planActivatedAt: new Date().toISOString(),
        stripeSessionId: session.id,
        ...(planId ? { plan: planId } : {})
      }
    });

    if (updateRes.status === 200) {
      console.log('Plan activated for:', email);
    } else {
      console.error('Failed to update user:', updateRes);
    }
  }

  // Handle subscription cancelled
  if (stripeEvent.type === 'customer.subscription.deleted') {
    const subscription = stripeEvent.data.object;
    const email = subscription.metadata && subscription.metadata.email;

    if (!email) {
      console.log('No email in subscription metadata, skipping deactivation');
      return { statusCode: 200, body: 'OK - no email' };
    }

    console.log('Deactivating plan for:', email);

    // Find user by email in Supabase
    const listRes = await supabaseRequest('GET', `/auth/v1/admin/users?email=${encodeURIComponent(email)}&per_page=1`, null);

    if (listRes.status !== 200 || !listRes.data.users || listRes.data.users.length === 0) {
      console.error('User not found:', email);
      return { statusCode: 200, body: 'OK - user not found' };
    }

    const user = listRes.data.users[0];
    const existingMeta = user.user_metadata || {};

    // Deactivate plan
    const updateRes = await supabaseRequest('PUT', `/auth/v1/admin/users/${user.id}`, {
      user_metadata: {
        ...existingMeta,
        planActive: false,
        planCancelledAt: new Date().toISOString()
      }
    });

    if (updateRes.status === 200) {
      console.log('Plan deactivated for:', email);
    } else {
      console.error('Failed to deactivate user:', updateRes);
    }
  }

  return { statusCode: 200, body: JSON.stringify({ received: true }) };
};
