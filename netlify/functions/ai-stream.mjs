// Streaming AI endpoint (Netlify v2 function).
// Pipes Anthropic's server-sent events straight back to the browser so
// document drafts appear word-by-word with no single-shot timeout.

// Live UK-law web search via Brave (best-effort; returns '' on any failure)
async function braveSearch(query){
  const key = process.env.BRAVE_SEARCH_KEY;
  if(!key) return '';
  try {
    const url = 'https://api.search.brave.com/res/v1/web/search?q=' +
      encodeURIComponent(query + ' UK law legislation 2024 2025') +
      '&count=5&country=gb&search_lang=en';
    const r = await fetch(url, {
      headers: { 'Accept': 'application/json', 'Accept-Encoding': 'gzip', 'X-Subscription-Token': key }
    });
    if(!r.ok) return '';
    const data = await r.json();
    if(!data.web || !data.web.results) return '';
    return data.web.results.slice(0, 5).map((x, i) =>
      `[${i + 1}] ${x.title}\n${x.description || ''}\nSource: ${x.url}`
    ).join('\n\n');
  } catch(e) { return ''; }
}

export default async (req) => {
  const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS'
  };

  if (req.method === 'OPTIONS') {
    return new Response('', { headers: cors });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405, headers: { ...cors, 'Content-Type': 'application/json' }
    });
  }

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    return new Response(JSON.stringify({ error: 'Server not configured' }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' }
    });
  }

  let payload;
  try {
    payload = await req.json();
  } catch (e) {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), {
      status: 400, headers: { ...cors, 'Content-Type': 'application/json' }
    });
  }

  // Optional live web search (Brave) injected into the system prompt
  if (payload.web_search && payload.messages && payload.messages.length > 0) {
    const q = payload.messages[payload.messages.length - 1].content;
    const results = await braveSearch(q);
    if (results) {
      payload.system = (payload.system || '') +
        '\n\n--- LIVE WEB SEARCH RESULTS (use these for up-to-date UK law) ---\n' +
        results +
        '\n--- END OF SEARCH RESULTS ---\n' +
        'Where relevant, reflect the latest UK legislation and note if a law has recently changed.';
    }
  }
  delete payload.web_search;

  payload.stream = true;
  payload.model = payload.model || 'claude-sonnet-4-5';

  const upstream = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': key,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify(payload)
  });

  // On error, return the upstream error body as-is (not a stream)
  if (!upstream.ok) {
    const errBody = await upstream.text();
    return new Response(errBody, {
      status: upstream.status,
      headers: { ...cors, 'Content-Type': 'application/json' }
    });
  }

  // Stream the SSE response straight through to the client
  return new Response(upstream.body, {
    status: 200,
    headers: {
      ...cors,
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache',
      'X-Accel-Buffering': 'no'
    }
  });
};
