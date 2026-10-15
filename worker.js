export default {
 async fetch(request, env) {
  const url=new URL(request.url);
  if(url.pathname==='/api/kiosk/catalog') {
   if(request.method!=='GET')return new Response('Method not allowed',{status:405});
   if(!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY)
     return Response.json({error:'Catálogo indisponível'},{status:503,headers:{'Cache-Control':'no-store'}});
   const upstream=await fetch(env.SUPABASE_URL+'/rest/v1/rpc/kiosk_public_catalog',{
     method:'POST',headers:{'Content-Type':'application/json',
       'apikey':env.SUPABASE_SERVICE_ROLE_KEY,
       'Authorization':'Bearer '+env.SUPABASE_SERVICE_ROLE_KEY},
     body:'{}'
   });
   if(!upstream.ok)return Response.json({error:'Não foi possível carregar o cardápio'},{status:502,headers:{'Cache-Control':'no-store'}});
   const data=await upstream.json();
   return Response.json({products:Array.isArray(data)?data:[]},{headers:{'Cache-Control':'no-store'}});
  }
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
