import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,is_anonymous boolean default false);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;`);
for(const f of ['01-schema.sql','04-qr-fixo-clientes.sql','05-dashboard.sql','05-dashboard.sql'])await db.exec(await readFile(new URL('../supabase/'+f,import.meta.url),'utf8'));
const ids={};let n=0;for(const role of ['admin','cashier','kitchen','bar','customer','inactive']){const id=`00000000-0000-4000-8000-${String(++n).padStart(12,'0')}`;ids[role]=id;await db.query('insert into auth.users values($1,$2,false)',[id,role+'@test.invalid']);if(role!=='customer')await db.query('insert into dragons.staff values($1,$2,$3,$4)',[id,role,role==='inactive'?'cashier':role,role!=='inactive'])}
await db.exec(`insert into dragons.tables(name) values('1'); insert into dragons.products values('agua','Água atual','','Bebidas','bar',9999,'',true),('prato','Prato atual','','Comida','kitchen',99999,'',false);`);
async function sale(at,items=[],paid=true){
 const v=(await db.query("insert into dragons.visits(table_id,mode,closed_at) select id,'mixed',now() from dragons.tables returning id")).rows[0].id;
 const t=(await db.query("insert into dragons.tabs(visit_id,name,status) values($1,'Conta de teste',$2) returning id",[v,paid?'paid':'open'])).rows[0].id;
 const o=(await db.query("insert into dragons.orders(tab_id,user_id,request_id,customer_name,created_at) values($1,$2,gen_random_uuid(),'Cliente teste','2020-01-01') returning id",[t,ids.customer])).rows[0].id;
 let cents=0;for(const [pid,name,station,unit,quantity,status='delivered'] of items){await db.query('insert into dragons.items(order_id,product_id,name,station,unit_cents,quantity,status) values($1,$2,$3,$4,$5,$6,$7)',[o,pid,name,station,unit,quantity,status]);if(status!=='canceled')cents+=unit*quantity}
 if(paid)await db.query("insert into dragons.payments(tab_id,amount_cents,method,paid_at,cashier_id) values($1,$2,'pix',$3,$4)",[t,cents,at,ids.cashier]);return t;
}
await sale('2026-01-01T03:59:59Z',[['agua','Água antiga','bar',500,2]]); // 31/12 Cuiabá
await sale('2026-01-01T04:00:00Z',[['agua','Água','bar',600,1],['prato','Prato','kitchen',2000,2],['agua','Cancelada','bar',500,10,'canceled']]);
await sale('2026-01-03T03:59:59Z',[['agua','Água','bar',500,2]]); // 02/01
await sale('2026-01-03T04:00:00Z',[['prato','Prato','kitchen',2000,1]]);
await sale('2026-01-02T12:00:00Z',[['agua','Não paga','bar',1000,50]],false);
for(let i=0;i<105;i++)await sale('2026-06-01T12:00:00Z');
async function report(who,from='2026-01-01',to='2026-01-02'){
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||'']);await db.exec('set role authenticated');try{return(await db.query('select public.dashboard_report($1,$2) result',[from,to])).rows[0].result}finally{await db.exec('reset role')}
}
let tests=0;async function test(name,fn){await fn();tests++;console.log('✓ '+name)}
await test('Caixa e admin acessam; outros perfis e sessões vazias são bloqueados',async()=>{await report('admin');await report('cashier');for(const who of ['kitchen','bar','customer','inactive','missing'])await assert.rejects(()=>report(who),/somente/)});
await test('Anon não recebe permissão para executar relatório',async()=>{await db.exec('set role anon');try{await assert.rejects(()=>db.query("select public.dashboard_report('2026-01-01','2026-01-02')"),/permission denied/)}finally{await db.exec('reset role')}});
await test('Data do recebimento e fuso Cuiabá determinam o período exato',async()=>{const r=await report('cashier');assert.deepEqual(r.daily,[{day:'2026-01-01',cents:4600,count:1},{day:'2026-01-02',cents:1000,count:1}]);assert.equal(r.payments.length,2);assert.equal(r.methods[0].cents,5600)});
await test('Produtos excluem cancelados/abertos, usam preço histórico e incluem desativados',async()=>{const r=await report('cashier');assert.deepEqual(r.products.map(p=>[p.product_id,p.quantity,p.cents]),[['agua',3,1600],['prato',2,4000]]);assert.equal(r.products.reduce((n,p)=>n+p.cents,0),5600)});
await test('Renomear produto não divide seu total nem duplica recebimentos',async()=>{const r=await report('cashier','2025-12-31','2026-01-02');assert.equal(r.products.length,2);const p=r.products.find(p=>p.product_id==='agua');assert.equal(p.quantity,5);assert.equal(p.name,'Água');assert.equal(p.cents,2600);assert.equal(r.daily.reduce((n,p)=>n+p.count,0),3)});
await test('Lista limitada a 100 mantém KPIs e gráficos de todo período',async()=>{const r=await report('cashier','2025-01-01','2026-12-31');assert.equal(r.payments.length,100);assert.equal(r.daily.reduce((n,p)=>n+p.count,0),109);assert.equal(r.daily.reduce((n,p)=>n+p.cents,0),8600);assert.ok(!JSON.stringify(r).includes('cashier_id'));assert.ok(!JSON.stringify(r).includes('user_id'))});
await test('Período vazio retorna arrays vazios e multi-ano é aceito',async()=>{const r=await report('cashier','2020-01-01','2024-12-31');assert.deepEqual(r.daily,[]);assert.deepEqual(r.products,[])});
await test('Limites, nulos, datas invertidas e infinitas são rejeitados',async()=>{for(const [a,b] of [[null,'2026-01-01'],['2026-02-02','2026-01-01'],['2000-01-01','2026-01-01'],['infinity','infinity']])await assert.rejects(()=>report('cashier',a,b),/período válido/)});
await test('Atualização repetida preserva QR e fluxo do caixa',async()=>{const qr=(await db.query('select qr_token from dragons.tables')).rows[0].qr_token;await db.exec(await readFile(new URL('../supabase/05-dashboard.sql',import.meta.url),'utf8'));assert.equal((await db.query('select qr_token from dragons.tables')).rows[0].qr_token,qr);await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.cashier]);await db.exec('set role authenticated');try{assert.ok((await db.query("select public.db_action('cashier_state','{}') result")).rows[0].result.tables)}finally{await db.exec('reset role')}});
console.log(`\n${tests} verificações do backend do dashboard passaram.`);await db.close();
