-- Dragons Beer / projeto Supabase novo e exclusivo para este estabelecimento.
-- Execute UMA VEZ. A transação desfaz tudo se ocorrer erro.
begin;
create schema if not exists dragons;
revoke all on schema dragons from public, anon, authenticated;
create table dragons.staff(user_id uuid primary key references auth.users(id), name text not null, role text not null check(role in ('admin','cashier','kitchen','bar')), active boolean not null default true);
create table dragons.tables(id uuid primary key default gen_random_uuid(), name text not null unique check(length(name) between 1 and 40), active boolean not null default true);
create table dragons.products(id text primary key, name text not null check(length(name) between 1 and 120), description text not null default '', category text not null, station text not null check(station in ('kitchen','bar')), price_cents integer not null check(price_cents between 1 and 1000000), image text not null default '', active boolean not null default true);
create table dragons.visits(id uuid primary key default gen_random_uuid(), table_id uuid not null references dragons.tables, mode text not null check(mode in ('shared','individual')), token uuid not null unique default gen_random_uuid(), opened_at timestamptz not null default now(), closed_at timestamptz);
create unique index one_open_visit on dragons.visits(table_id) where closed_at is null;
create table dragons.tabs(id uuid primary key default gen_random_uuid(), visit_id uuid not null references dragons.visits, owner_id uuid references auth.users, name text not null, status text not null default 'open' check(status in ('open','requested','attending','paid')), payment_method text check(payment_method in ('pix','credit','debit','cash')), requested_at timestamptz, acknowledged_at timestamptz, paid_at timestamptz, acknowledged_by uuid references auth.users, created_at timestamptz not null default now(), unique(visit_id,owner_id));
create unique index one_shared_tab on dragons.tabs(visit_id) where owner_id is null;
create table dragons.members(visit_id uuid not null references dragons.visits, user_id uuid not null references auth.users, tab_id uuid not null references dragons.tabs, name text not null, primary key(visit_id,user_id));
create table dragons.orders(id uuid primary key default gen_random_uuid(), tab_id uuid not null references dragons.tabs, user_id uuid not null references auth.users, request_id uuid not null, customer_name text not null, note text not null default '', created_at timestamptz not null default now(), unique(user_id,request_id));
create table dragons.items(id uuid primary key default gen_random_uuid(), order_id uuid not null references dragons.orders, product_id text not null references dragons.products, name text not null, station text not null check(station in ('kitchen','bar')), unit_cents integer not null check(unit_cents>0), quantity integer not null check(quantity between 1 and 50), status text not null default 'pending' check(status in ('pending','preparing','ready','delivered','canceled')), cancel_reason text, updated_at timestamptz not null default now());
create table dragons.payments(id uuid primary key default gen_random_uuid(), tab_id uuid not null unique references dragons.tabs, amount_cents integer not null check(amount_cents>=0), method text not null check(method in ('pix','credit','debit','cash')), paid_at timestamptz not null default now(), cashier_id uuid not null references auth.users);
create table dragons.audit(id bigint generated always as identity primary key, user_id uuid, action text not null, target uuid, detail jsonb, created_at timestamptz not null default now());
create index orders_tab on dragons.orders(tab_id);
create index items_order on dragons.items(order_id);
create index tabs_visit on dragons.tabs(visit_id);
create index payments_date on dragons.payments(paid_at);
-- Nenhum cliente acessa tabelas diretamente. Todas as operações passam pela API RPC.
do $$ declare t record; begin for t in select tablename from pg_tables where schemaname='dragons' loop execute format('alter table dragons.%I enable row level security',t.tablename); end loop; end $$;
revoke all on all tables in schema dragons from public, anon, authenticated;
create function dragons.total(p_tab uuid) returns integer language sql stable set search_path='' as $$
 select coalesce(sum(i.unit_cents*i.quantity),0)::integer from dragons.items i join dragons.orders o on o.id=i.order_id where o.tab_id=p_tab and i.status<>'canceled'
$$;
create function dragons.tab_json(p_tab uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(t)-'owner_id'-'acknowledged_by' || jsonb_build_object('total_cents',dragons.total(t.id),'table_name',d.name,'mode',v.mode,
 'orders',coalesce((select jsonb_agg(to_jsonb(o)-'user_id'-'request_id'||jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(i) order by i.id) from dragons.items i where i.order_id=o.id),'[]'::jsonb)) order by o.created_at desc) from dragons.orders o where o.tab_id=t.id),'[]'::jsonb))
 from dragons.tabs t join dragons.visits v on v.id=t.visit_id join dragons.tables d on d.id=v.table_id where t.id=p_tab
$$;
create function public.db_action(op text,args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid := auth.uid(); staff_role text; result jsonb; v dragons.visits; t dragons.tabs; p dragons.products; it dragons.items;
 tab_id uuid; target_id uuid; ord_id uuid; req_id uuid; x jsonb; qty integer; amount integer; old_role text; d_from date; d_to date;
begin
 if uid is null then raise exception 'Faça login novamente.'; end if;
 select s.role into staff_role from dragons.staff s where s.user_id=uid and s.active;
 if op='profile' then
   return jsonb_build_object('role',staff_role,'name',(select name from dragons.staff where user_id=uid),'user_id',uid);
 elsif op='join' then
   if length(trim(coalesce(args->>'name',''))) not between 1 and 80 then raise exception 'Informe seu nome (até 80 caracteres).'; end if;
   select * into v from dragons.visits where token=(args->>'token')::uuid and closed_at is null for update;
   if not found then raise exception 'Atendimento indisponível. Peça o QR Code atual ao caixa.'; end if;
   select m.tab_id into tab_id from dragons.members m where m.visit_id=v.id and m.user_id=uid;
   if tab_id is null then
     if v.mode='shared' then
       select id into tab_id from dragons.tabs where visit_id=v.id and owner_id is null;
       if tab_id is null then insert into dragons.tabs(visit_id,name) values(v.id,'Conta da mesa') returning id into tab_id; end if;
     else
       insert into dragons.tabs(visit_id,owner_id,name) values(v.id,uid,trim(args->>'name')) returning id into tab_id;
     end if;
     insert into dragons.members values(v.id,uid,tab_id,trim(args->>'name'));
   end if;
   return jsonb_build_object('tab_id',tab_id,'visit_id',v.id);
 elsif op='customer_state' then
   select m.tab_id into tab_id from dragons.members m where m.user_id=uid and m.tab_id=(args->>'tab_id')::uuid;
   if tab_id is null then raise exception 'Comanda não autorizada.'; end if;
   return jsonb_build_object('tab',dragons.tab_json(tab_id),'products',coalesce((select jsonb_agg(to_jsonb(pr) order by category,name) from dragons.products pr where active),'[]'::jsonb));
 elsif op in ('place_order','request_close') then
   select * into t from dragons.tabs where id=(args->>'tab_id')::uuid for update;
   if t.id is null or not exists(select 1 from dragons.members m where m.tab_id=t.id and m.user_id=uid) then raise exception 'Comanda não autorizada.'; end if;
   if op='place_order' then
     req_id := (args->>'request_id')::uuid;
     if req_id is null then raise exception 'Identificador de pedido obrigatório.'; end if;
     select id, o.tab_id into ord_id,tab_id from dragons.orders o where user_id=uid and request_id=req_id;
     if ord_id is not null then
       if tab_id<>t.id then raise exception 'Identificador já utilizado.'; end if;
       return jsonb_build_object('order_id',ord_id,'duplicate',true);
     end if;
     if t.status<>'open' or exists(select 1 from dragons.visits where id=t.visit_id and closed_at is not null) then raise exception 'Esta comanda não aceita novos pedidos.'; end if;
     if jsonb_typeof(args->'items') is distinct from 'array' or jsonb_array_length(args->'items') not between 1 and 50 then raise exception 'Pedido inválido.'; end if;
     if length(coalesce(args->>'note',''))>500 then raise exception 'Observação: máximo 500 caracteres.'; end if;
     insert into dragons.orders(tab_id,user_id,request_id,customer_name,note)
       select t.id,uid,req_id,m.name,coalesce(args->>'note','') from dragons.members m where m.tab_id=t.id and m.user_id=uid returning id into ord_id;
     for x in select value from jsonb_array_elements(args->'items') loop
       qty := (x->>'quantity')::integer;
       if qty is null or qty not between 1 and 50 then raise exception 'Quantidade inválida.'; end if;
       select * into p from dragons.products where id=x->>'product_id' and active for share;
       if not found then raise exception 'Produto indisponível. Atualize o cardápio.'; end if;
       if x ? 'expected_unit_cents' and (x->>'expected_unit_cents')::integer is distinct from p.price_cents then raise exception 'O preço de um produto mudou. Confira o carrinho antes de enviar novamente.'; end if;
       insert into dragons.items(order_id,product_id,name,station,unit_cents,quantity) values(ord_id,p.id,p.name,p.station,p.price_cents,qty);
     end loop;
     target_id:=ord_id; result:=jsonb_build_object('order_id',ord_id);
   else
     if args->>'method' is null or args->>'method' not in ('pix','credit','debit','cash') then raise exception 'Forma de pagamento inválida.'; end if;
     if t.status in ('requested','attending') then return jsonb_build_object('ok',true); end if;
     if t.status<>'open' then raise exception 'Comanda já encerrada.'; end if;
     update dragons.tabs set status='requested',payment_method=args->>'method',requested_at=now() where id=t.id;
     target_id:=t.id; result:=jsonb_build_object('ok',true);
   end if;
 else
   if staff_role is null then raise exception 'Acesso restrito à equipe.'; end if;
   if op='station_state' then
     if args->>'station' is null or args->>'station' not in ('kitchen','bar') or (staff_role not in ('admin','cashier') and staff_role<>args->>'station') then raise exception 'Setor não autorizado.'; end if;
     return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('table_name',d.name,'tab_name',tt.name,'customer_name',o.customer_name,'note',o.note,'created_at',o.created_at) order by o.created_at) from dragons.items i join dragons.orders o on o.id=i.order_id join dragons.tabs tt on tt.id=o.tab_id join dragons.visits vv on vv.id=tt.visit_id join dragons.tables d on d.id=vv.table_id where i.station=args->>'station' and i.status not in ('delivered','canceled') and vv.closed_at is null),'[]'::jsonb));
   elsif op='advance_item' then
     -- Mesma ordem de bloqueios do caixa: comanda antes do item.
     select o.tab_id into tab_id from dragons.items i join dragons.orders o on o.id=i.order_id where i.id=(args->>'id')::uuid;
     select * into t from dragons.tabs where id=tab_id for update;
     select * into it from dragons.items where id=(args->>'id')::uuid for update;
     if it.id is null or (staff_role not in ('admin','cashier') and staff_role<>it.station) then raise exception 'Item não autorizado.'; end if;
     if t.status='paid' then raise exception 'Comanda encerrada.'; end if;
     if args->>'next' = it.status then return jsonb_build_object('ok',true); end if;
     if not ((it.status='pending' and args->>'next'='preparing') or (it.status='preparing' and args->>'next'='ready') or (it.status='ready' and args->>'next'='delivered')) then raise exception 'Etapa inválida. Atualize a tela.'; end if;
     update dragons.items set status=args->>'next',updated_at=now() where id=it.id;
     target_id:=it.id; result:=jsonb_build_object('ok',true);
   else
     if staff_role not in ('admin','cashier') then raise exception 'Acesso restrito ao caixa.'; end if;
     if op='cashier_state' then
       return jsonb_build_object('tables',coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('visit',(select to_jsonb(vv)||jsonb_build_object('tabs',coalesce((select jsonb_agg(dragons.tab_json(tt.id) order by tt.created_at) from dragons.tabs tt where tt.visit_id=vv.id),'[]'::jsonb)) from dragons.visits vv where vv.table_id=d.id and vv.closed_at is null)) order by d.name) from dragons.tables d),'[]'::jsonb));
     elsif op='open_visit' then
       perform 1 from dragons.tables where id=(args->>'table_id')::uuid and active for update;
       if not found then raise exception 'Mesa indisponível.'; end if;
       select * into v from dragons.visits where table_id=(args->>'table_id')::uuid and closed_at is null;
       if found then return to_jsonb(v); end if;
       if args->>'mode' is null or args->>'mode' not in ('shared','individual') then raise exception 'Escolha o tipo de conta.'; end if;
       insert into dragons.visits(table_id,mode) values((args->>'table_id')::uuid,args->>'mode') returning * into v;
       result:=to_jsonb(v); target_id:=v.id;
     elsif op='close_visit' then
       select * into v from dragons.visits where id=(args->>'id')::uuid for update;
       if v.id is null then raise exception 'Atendimento não encontrado.'; end if;
       if exists(select 1 from dragons.tabs where visit_id=v.id and status<>'paid') then raise exception 'Encerre todas as comandas antes de liberar a mesa.'; end if;
       update dragons.visits set closed_at=coalesce(closed_at,now()) where id=v.id;
       result:=jsonb_build_object('ok',true);target_id:=v.id;
     elsif op in ('acknowledge','reopen_tab','pay','cancel_item') then
       tab_id:=(args->>'tab_id')::uuid;
       select * into t from dragons.tabs where id=tab_id for update;
       if t.id is null then raise exception 'Comanda não encontrada.'; end if;
       if op='pay' and t.status='paid' then return jsonb_build_object('ok',true,'duplicate',true); end if;
       if t.status='paid' then raise exception 'Comanda encerrada.'; end if;
       if op='acknowledge' then
         if t.status='attending' then return jsonb_build_object('ok',true); end if;
         if t.status<>'requested' then raise exception 'Solicitação não está pendente.'; end if;
         update dragons.tabs set status='attending',acknowledged_at=now(),acknowledged_by=uid where id=t.id;
       elsif op='reopen_tab' then
         update dragons.tabs set status='open',requested_at=null,acknowledged_at=null,acknowledged_by=null,payment_method=null where id=t.id;
       elsif op='cancel_item' then
         if length(trim(coalesce(args->>'reason',''))) not between 3 and 300 then raise exception 'Informe o motivo do cancelamento.'; end if;
         select i.* into it from dragons.items i join dragons.orders o on o.id=i.order_id where i.id=(args->>'id')::uuid and o.tab_id=t.id for update of i;
         if not found then raise exception 'Item não encontrado nesta comanda.'; end if;
         update dragons.items set status='canceled',cancel_reason=trim(args->>'reason'),updated_at=now() where id=it.id;
       else
         if args->>'method' is null or args->>'method' not in ('pix','credit','debit','cash') then raise exception 'Forma de pagamento inválida.'; end if;
         if exists(select 1 from dragons.items i join dragons.orders o on o.id=i.order_id where o.tab_id=t.id and i.status not in ('delivered','canceled')) then raise exception 'Há itens não entregues. Entregue ou cancele antes de receber.'; end if;
         amount:=dragons.total(t.id);
         if (args->>'expected_cents')::integer is distinct from amount then raise exception 'O total mudou. Atualize a comanda e confira o pagamento.'; end if;
         insert into dragons.payments(tab_id,amount_cents,method,cashier_id) values(t.id,amount,args->>'method',uid);
         update dragons.tabs set status='paid',paid_at=now(),payment_method=args->>'method' where id=t.id;
       end if;
       target_id:=t.id;result:=jsonb_build_object('ok',true);
     elsif op='report' then
       d_from:=(args->>'from')::date; d_to:=(args->>'to')::date;
       if d_from is null or d_to is null or d_to<d_from or d_to-d_from>366 then raise exception 'Escolha um intervalo de até 367 dias.'; end if;
       return jsonb_build_object('payments',coalesce((select jsonb_agg(to_jsonb(pp)||jsonb_build_object('tab_name',tt.name,'table_name',dd.name) order by pp.paid_at desc) from dragons.payments pp join dragons.tabs tt on tt.id=pp.tab_id join dragons.visits vv on vv.id=tt.visit_id join dragons.tables dd on dd.id=vv.table_id where (pp.paid_at at time zone 'America/Cuiaba')::date between d_from and d_to),'[]'::jsonb),
       'products',coalesce((select jsonb_agg(to_jsonb(r) order by r.quantity desc) from (select i.product_id,i.name,i.station,sum(i.quantity)::integer quantity,sum(i.quantity*i.unit_cents)::bigint cents from dragons.items i join dragons.orders o on o.id=i.order_id join dragons.payments pp on pp.tab_id=o.tab_id where i.status<>'canceled' and (pp.paid_at at time zone 'America/Cuiaba')::date between d_from and d_to group by i.product_id,i.name,i.station) r),'[]'::jsonb));
     else
       if staff_role<>'admin' then raise exception 'Acesso restrito à administração.'; end if;
       if op='admin_state' then
         return jsonb_build_object('products',coalesce((select jsonb_agg(to_jsonb(pr) order by category,name) from dragons.products pr),'[]'::jsonb),'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('email',u.email) order by s.name) from dragons.staff s join auth.users u on u.id=s.user_id),'[]'::jsonb),'tables',coalesce((select jsonb_agg(to_jsonb(d) order by name) from dragons.tables d),'[]'::jsonb));
       elsif op='save_table' then
         if args->>'id' is null or args->>'id'='' then
           insert into dragons.tables(name) values(trim(args->>'name')) returning id into target_id;
         else
           target_id:=(args->>'id')::uuid;
           if not (args->>'active')::boolean and exists(select 1 from dragons.visits where table_id=target_id and closed_at is null) then raise exception 'Libere a mesa antes de desativar.'; end if;
           update dragons.tables set name=trim(args->>'name'),active=(args->>'active')::boolean where id=target_id;
         end if;
       elsif op='save_product' then
         if length(coalesce(args->>'description',''))>1000 or length(coalesce(args->>'image',''))>2000 then raise exception 'Texto muito longo.'; end if;
         if coalesce(args->>'image','')<>'' and not (args->>'image' like '/assets/%' or args->>'image' like 'https://%') then raise exception 'Imagem deve ser URL https ou arquivo em /assets/.'; end if;
         insert into dragons.products(id,name,description,category,station,price_cents,image,active) values(coalesce(nullif(args->>'id',''),gen_random_uuid()::text),trim(args->>'name'),coalesce(args->>'description',''),trim(args->>'category'),args->>'station',(args->>'price_cents')::integer,coalesce(args->>'image',''),coalesce((args->>'active')::boolean,true))
         on conflict(id) do update set name=excluded.name,description=excluded.description,category=excluded.category,station=excluded.station,price_cents=excluded.price_cents,image=excluded.image,active=excluded.active;
       elsif op='save_staff' then
         -- Serializa alterações de administradores para preservar ao menos um ativo.
         perform pg_advisory_xact_lock(834991);
         select id into target_id from auth.users where lower(email)=lower(trim(args->>'email')) and coalesce(is_anonymous,false)=false;
         if target_id is null then raise exception 'Crie primeiro este usuário em Supabase > Authentication > Users.'; end if;
         if args->>'role' not in ('admin','cashier','bar','kitchen') then raise exception 'Perfil inválido.'; end if;
         select role into old_role from dragons.staff where user_id=target_id and active;
         if old_role='admin' and (args->>'role'<>'admin' or not (args->>'active')::boolean) and (select count(*) from dragons.staff where role='admin' and active)<=1 then raise exception 'Mantenha pelo menos um administrador ativo.'; end if;
         insert into dragons.staff(user_id,name,role,active) values(target_id,trim(args->>'name'),args->>'role',(args->>'active')::boolean) on conflict(user_id) do update set name=excluded.name,role=excluded.role,active=excluded.active;
       else raise exception 'Operação desconhecida.';
       end if;
       result:=jsonb_build_object('ok',true);
     end if;
   end if;
 end if;
 insert into dragons.audit(user_id,action,target,detail) values(uid,op,target_id,case when op='cancel_item' then jsonb_build_object('item',args->>'id','reason',args->>'reason') when op='pay' then jsonb_build_object('cents',amount,'method',args->>'method') when op='advance_item' then jsonb_build_object('next',args->>'next') else '{}'::jsonb end);
 return result;
end $$;
revoke all on all functions in schema dragons from public,anon,authenticated;
revoke all on function public.db_action(text,jsonb) from public,anon,authenticated;
grant execute on function public.db_action(text,jsonb) to authenticated;
commit;
