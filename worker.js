export default {
 async fetch(request, env) {
  const url=new URL(request.url);
  if(url.pathname==='/api/config') {
   const configured=!!env.SUPABASE_URL && !!env.SUPABASE_PUBLISHABLE_KEY;
   return Response.json({configured,url:env.SUPABASE_URL||'',key:env.SUPABASE_PUBLISHABLE_KEY||'',turnstile:env.TURNSTILE_SITE_KEY||'',google:env.GOOGLE_LOGIN_ENABLED==='true',facebook:env.FACEBOOK_LOGIN_ENABLED==='true',version:'3.0.0'},{headers:{'Cache-Control':'no-store'}});
  }
  const response=await env.ASSETS.fetch(request);
  const headers=new Headers(response.headers);
  headers.set('X-Content-Type-Options','nosniff');
  headers.set('Referrer-Policy','no-referrer');
  headers.set('X-Frame-Options','DENY');
  headers.set('Permissions-Policy','camera=(), microphone=(), geolocation=()');
  if((headers.get('Content-Type')||'').includes('text/html')) headers.set('Cache-Control','no-cache');
  return new Response(response.body,{status:response.status,headers});
 }
};
