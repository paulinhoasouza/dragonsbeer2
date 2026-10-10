-- V2: execute APÓS 01-schema.sql, sem executar 01 novamente.
-- Preserva dados existentes. Finalize atendimentos anônimos antes de atualizar.
begin;
alter table dragons.tables add column if not exists qr_token uuid not null default gen_random_uuid();
create unique index if not exists tables_qr_unique on dragons.tables(qr_token);
alter table dragons.visits drop constraint if exists visits_mode_check;
alter table dragons.visits add constraint visits_mode_check check(mode in ('shared','individual','mixed'));
create or replace function dragons.valid_cpf(input text) returns boolean language plpgsql immutable set search_path='' as $$
declare c text:=regexp_replace(coalesce(input,''),'[^0-9]','','g'); s integer; d integer; i integer; j integer;
begin
 if length(c)<>11 or c=repeat(left(c,1),11) then return false; end if;
 for j in 9..10 loop
   s:=0;
   for i in 1..j loop s:=s+substr(c,i,1)::integer*(j+2-i); end loop;
   d:=(s*10)%11; if d=10 then d:=0; end if;
   if d<>substr(c,j+1,1)::integer then return false; end if;
 end loop;
 return true;
end $$;
create table if not exists dragons.customer_profiles(
 user_id uuid primary key references auth.users(id),
 name text not null check(length(trim(name)) between 3 and 80),
 cpf text not null unique check(cpf ~ '^[0-9]{11}$' and dragons.valid_cpf(cpf)),
 phone text not null check(phone ~ '^[1-9][0-9]9[0-9]{8}$'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table dragons.customer_profiles enable row level security;
revoke all on dragons.customer_profiles from public,anon,authenticated;
-- Implementação anterior torna-se interna, inacessível pela API.
do $$ begin
 if to_regprocedure('dragons.db_action_v1(text,jsonb)') is null then
   alter function public.db_action(text,jsonb) set schema dragons;
   alter function dragons.db_action(text,jsonb) rename to db_action_v1;
 end if;
end $$;
revoke all on function dragons.db_action_v1(text,jsonb) from public,anon,authenticated;
create or replace function dragons.tab_json(p_tab uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(t)-'owner_id'-'acknowledged_by' || jsonb_build_object('total_cents',dragons.total(t.id),'table_name',d.name,
 'mode',case when t.owner_id is null then 'shared' else 'individual' end,'visit_closed_at',v.closed_at,
 'orders',coalesce((select jsonb_agg(to_jsonb(o)-'user_id'-'request_id'||jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(i) order by i.id) from dragons.items i where i.order_id=o.id),'[]'::jsonb)) order by o.created_at desc) from dragons.orders o where o.tab_id=t.id),'[]'::jsonb))
 from dragons.tabs t join dragons.visits v on v.id=t.visit_id join dragons.tables d on d.id=v.table_id where t.id=p_tab
$$;
-- O QR só expõe nome da mesa; não retorna clientes, comandas ou consumo.
create or replace function public.table_context(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d dragons.tables;
begin
 select * into d from dragons.tables where qr_token=p_token and active;
 if not found then raise exception 'Mesa indisponível. Consulte a equipe.'; end if;
 return jsonb_build_object('name',d.name);
end $$;
revoke all on function public.table_context(uuid) from public,anon,authenticated;
grant execute on function public.table_context(uuid) to anon,authenticated;
create or replace function public.db_action(op text,args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); staff_role text; d dragons.tables; v dragons.visits; t dragons.tabs; cp dragons.customer_profiles;
 chosen text; cpf_value text; phone_value text;
begin
 if uid is null then raise exception 'Faça login novamente.'; end if;
 select role into staff_role from dragons.staff where user_id=uid and active;
 if op in ('get_customer_profile','save_customer_profile','customer_entry','join','customer_state','place_order','request_close') then
   if not exists(select 1 from auth.users where id=uid and coalesce(is_anonymous,false)=false) then raise exception 'Entre com sua conta ou crie seu cadastro para continuar.'; end if;
   select * into cp from dragons.customer_profiles where user_id=uid;
   if op not in ('get_customer_profile','save_customer_profile') and cp.user_id is null then raise exception 'Complete nome, CPF e celular antes de acessar a comanda.'; end if;
 end if;
 if op='get_customer_profile' then
   return jsonb_build_object('profile',case when cp.user_id is null then null else to_jsonb(cp)-'user_id' end);
 elsif op='save_customer_profile' then
   if length(trim(coalesce(args->>'name',''))) not between 3 and 80 then raise exception 'Informe seu nome (3 a 80 caracteres).'; end if;
   cpf_value:=regexp_replace(coalesce(args->>'cpf',''),'[^0-9]','','g');
   if not dragons.valid_cpf(cpf_value) then raise exception 'CPF inválido. Confira os números.'; end if;
   phone_value:=regexp_replace(coalesce(args->>'phone',''),'[^0-9]','','g');
   if length(phone_value)=13 and left(phone_value,2)='55' then phone_value:=substr(phone_value,3); end if;
   if phone_value !~ '^[1-9][0-9]9[0-9]{8}$' then raise exception 'Informe celular brasileiro com DDD e 9 dígitos.'; end if;
   if cp.user_id is not null and cp.cpf<>cpf_value then raise exception 'Para corrigir o CPF cadastrado, procure o responsável pelo estabelecimento.'; end if;
   begin
     insert into dragons.customer_profiles(user_id,name,cpf,phone) values(uid,trim(args->>'name'),cpf_value,phone_value)
     on conflict(user_id) do update set name=excluded.name,phone=excluded.phone,updated_at=now() returning * into cp;
   exception when unique_violation then raise exception 'Não foi possível vincular este CPF. Se você já tem cadastro, entre na conta existente ou recupere sua senha.';
   end;
   insert into dragons.audit(user_id,action,target,detail) values(uid,op,uid,'{}');
   return jsonb_build_object('profile',to_jsonb(cp)-'user_id');
 elsif op in ('customer_entry','join') then
   select * into d from dragons.tables where qr_token=(args->>'token')::uuid and active for update;
   if not found then raise exception 'Mesa indisponível. Consulte a equipe.'; end if;
   select * into v from dragons.visits where table_id=d.id and closed_at is null for update;
   if v.id is not null then
     select tt.* into t from dragons.members m join dragons.tabs tt on tt.id=m.tab_id where m.visit_id=v.id and m.user_id=uid;
   end if;
   if op='customer_entry' then
     return jsonb_build_object('table_name',d.name,'tab_id',t.id,'tab_status',t.status,'shared_status',(select status from dragons.tabs where visit_id=v.id and owner_id is null));
   end if;
   if t.id is not null then return jsonb_build_object('tab_id',t.id,'visit_id',v.id); end if;
   chosen:=args->>'mode';
   if chosen is null or chosen not in ('shared','individual') then raise exception 'Escolha comanda individual ou compartilhada.'; end if;
   if v.id is null then insert into dragons.visits(table_id,mode) values(d.id,'mixed') returning * into v; end if;
   if chosen='shared' then
     select * into t from dragons.tabs where visit_id=v.id and owner_id is null for update;
     if t.id is not null and t.status<>'open' then raise exception 'A conta compartilhada está em fechamento. Escolha individual ou consulte o caixa.'; end if;
     if t.id is null then insert into dragons.tabs(visit_id,name) values(v.id,'Conta compartilhada') returning * into t; end if;
   else
     insert into dragons.tabs(visit_id,owner_id,name) values(v.id,uid,cp.name) returning * into t;
   end if;
   insert into dragons.members(visit_id,user_id,tab_id,name) values(v.id,uid,t.id,cp.name);
   insert into dragons.audit(user_id,action,target,detail) values(uid,'join',t.id,jsonb_build_object('mode',chosen));
   return jsonb_build_object('tab_id',t.id,'visit_id',v.id);
 elsif op='open_visit' then
   if staff_role is null or staff_role not in ('admin','cashier') then raise exception 'Acesso restrito ao caixa.'; end if;
   select * into d from dragons.tables where id=(args->>'table_id')::uuid and active for update;
   if not found then raise exception 'Mesa indisponível.'; end if;
   select * into v from dragons.visits where table_id=d.id and closed_at is null;
   if v.id is null then
     insert into dragons.visits(table_id,mode) values(d.id,'mixed') returning * into v;
     insert into dragons.audit(user_id,action,target,detail) values(uid,op,v.id,'{}');
   end if;
   return to_jsonb(v);
 else return dragons.db_action_v1(op,args);
 end if;
end $$;
revoke all on function public.db_action(text,jsonb) from public,anon,authenticated;
grant execute on function public.db_action(text,jsonb) to authenticated;
revoke all on all functions in schema dragons from public,anon,authenticated;
notify pgrst, 'reload schema';
commit;
