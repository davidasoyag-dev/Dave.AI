const stripe = require('stripe')('sk_test_51TUNmrDADESHMTvJ5pXy0bcT9Mo9BkBJcbKqW0b8GqTXSjMMsFoC6QGGHKbupwoymZ8FTm37ClQNiqxhQFiMl1s700hob24NT3');

const PLANS = {
  starter: { name: 'Dave.AI Starter', amount: 4900 },
  pro:     { name: 'Dave.AI Pro',     amount: 14900 },
  firm:    { name: 'Dave.AI Firm',    amount: 29900 }
};

exports.handler = async function(event) {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  try {
    const body = JSON.parse(event.body);
    const { plan, email, firstName, lastName, firm } = body;
    const planData = PLANS[plan];
    
    if (!planData) {
      return { statusCode: 400, body: JSON.stringify({ error: 'Invalid plan: ' + plan }) };
    }

    const sessionData = encodeURIComponent(JSON.stringify({
      plan, email, firstName, lastName, firm,
      planName: planData.name,
      planPrice: '£' + (planData.amount/100) + '/mo',
      planActive: true,
      trialStart: new Date().toISOString()
    }));

    const successUrl = 'https://meek-bonbon-bd461a.netlify.app/?payment=success&session=' + sessionData;
    const cancelUrl  = 'https://meek-bonbon-bd461a.netlify.app/index.html?payment=cancelled';

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ['card'],
      mode: 'subscription',
      customer_email: email,
      line_items: [{
        price_data: {
          currency: 'gbp',
          product_data: { name: planData.name },
          unit_amount: planData.amount,
          recurring: { interval: 'month' }
        },
        quantity: 1
      }],
      subscription_data: { trial_period_days: 14 },
      success_url: successUrl,
      cancel_url:  cancelUrl
    });

    return {
      statusCode: 200,
      headers: { 
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      },
      body: JSON.stringify({ url: session.url })
    };

  } catch (err) {
    console.error('Stripe error:', err.message);
    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: err.message })
    };
  }
};
