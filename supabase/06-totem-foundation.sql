-- Dragons Beer — 06: fundacao do autoatendimento
-- Executar APENAS apos 01 a 05. Nao altera comandas, mesas ou vendas anteriores.
-- Nenhuma chamada deste arquivo confirma pagamento por requisicao do navegador.
begin;

create table if not exists dragons.kiosk_orders (
  id uuid primary key default gen_random_uuid(),
  device_id text not null check (length(device_id) between 1 and 64),
  request_id uuid not null,
  status text not null default 'awaiting_payment'
    check (status in ('awaiting_payment','preparing','ready','delivered','canceled')),
  total_cents integer not null default 0 check (total_cents between 0 and 10000000),
  ticket_day date,
  ticket_number integer check (ticket_number between 1 and 9999),
  payment_method text check (payment_method in ('pix','card')),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  ready_at timestamptz,
  delivered_at timestamptz,
  unique(device_id,request_id),
  unique(ticket_day,ticket_number),
  check ((ticket_day is null and ticket_number is null) or
         (ticket_day is not null and ticket_number is not null))
);

create table if not exists dragons.kiosk_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references dragons.kiosk_orders(id),
  product_id text not null references dragons.products(id),
  product_name text not null,
  station text not null check (station in ('bar','kitchen')),
  unit_cents integer not null check (unit_cents > 0),
  quantity integer not null check (quantity between 1 and 50),
  note text not null default '' check (length(note) <= 200)
);

create table if not exists dragons.kiosk_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references dragons.kiosk_orders(id),
  provider text not null default 'mercadopago',
  provider_order_id text not null check (length(provider_order_id) between 1 and 128),
  method text not null check (method in ('pix','card')),
  status text not null default 'pending'
    check (status in ('pending','approved','failed','canceled','refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider,provider_order_id)
);
create unique index if not exists kiosk_one_pending_payment
  on dragons.kiosk_payment_attempts(order_id) where status='pending';
create unique index if not exists kiosk_one_approved_payment
  on dragons.kiosk_payment_attempts(order_id) where status='approved';

create table if not exists dragons.kiosk_daily_counters (
  ticket_day date primary key,
  last_number integer not null check (last_number between 1 and 9999)
);

create table if not exists dragons.kiosk_sections (
  order_id uuid not null references dragons.kiosk_orders(id),
  station text not null check (station in ('bar','kitchen')),
  scan_code uuid not null unique default gen_random_uuid(),
  received_at timestamptz,
  primary key(order_id,station)
);

create table if not exists dragons.kiosk_print_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references dragons.kiosk_orders(id),
  station text not null check (station in ('bar','kitchen')),
  payload jsonb not null,
  status text not null default 'pending'
    check (status in ('pending','leased','printed')),
  attempts integer not null default 0 check (attempts between 0 and 100),
  lease_until timestamptz,
  printed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(order_id,station)
);
create index if not exists kiosk_print_job_claim
  on dragons.kiosk_print_jobs(status,lease_until,created_at);

create table if not exists dragons.kiosk_calls (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references dragons.kiosk_orders(id),
  status text not null default 'queued' check (status in ('queued','announced')),
  created_at timestamptz not null default now(),
  announced_at timestamptz
);
create index if not exists kiosk_calls_queued
  on dragons.kiosk_calls(status,created_at);

-- Client e equipe nao recebem permissao direta para essas tabelas.
do $$
declare t text;
begin
 foreach t in array array[
 'kiosk_orders','kiosk_items','kiosk_payment_attempts','kiosk_daily_counters',
 'kiosk_sections','kiosk_print_jobs','kiosk_calls'] loop
   execute format('alter table dragons.%I enable row level security',t);
   execute format('revoke all on dragons.%I from public, anon, authenticated',t);
 end loop;
end $$;

-- Chamadas RPC sao exclusivas do backend com credencial service_role.
create or replace function public.kiosk_create_order(
  p_device_id text, p_request_id uuid, p_cart jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_id uuid;
  v_row jsonb;
  v_product dragons.products;
  v_qty integer;
  v_note text;
  v_total bigint := 0;
  v_count integer := 0;
  v_existing dragons.kiosk_orders;
begin
  if p_device_id is null or length(p_device_id) not between 1 and 64 or p_request_id is null then
    raise exception 'Totem ou identificador de solicitacao invalido.';
  end if;
  if p_cart is null or jsonb_typeof(p_cart)<>'array'
     or jsonb_array_length(p_cart) not between 1 and 30 then
    raise exception 'Carrinho deve conter de 1 a 30 linhas.';
  end if;
  insert into dragons.kiosk_orders(device_id,request_id)
    values(p_device_id,p_request_id)
    on conflict(device_id,request_id) do nothing returning id into v_id;
  if v_id is null then
    select * into v_existing from dragons.kiosk_orders
      where device_id=p_device_id and request_id=p_request_id;
    return jsonb_build_object('order_id',v_existing.id,'total_cents',v_existing.total_cents,
      'status',v_existing.status,'duplicate',true);
  end if;
  for v_row in select value from jsonb_array_elements(p_cart) loop
    if jsonb_typeof(v_row)<>'object' then raise exception 'Item invalido.'; end if;
    if jsonb_typeof(v_row->'quantity')<>'number' then raise exception 'Quantidade invalida.'; end if;
    v_qty := (v_row->>'quantity')::integer;
    if v_qty not between 1 and 50 then raise exception 'Quantidade fora do intervalo.'; end if;
    v_note := trim(coalesce(v_row->>'note',''));
    if length(v_note)>200 then raise exception 'Observacao excede 200 caracteres.'; end if;
    select * into v_product from dragons.products
      where id=v_row->>'product_id' and active for share;
    if not found then raise exception 'Produto indisponivel.'; end if;
    insert into dragons.kiosk_items(order_id,product_id,product_name,station,unit_cents,quantity,note)
      values(v_id,v_product.id,v_product.name,v_product.station,
        v_product.price_cents,v_qty,v_note);
    v_total := v_total + v_product.price_cents::bigint*v_qty;
    v_count := v_count + 1;
  end loop;
  if v_count=0 or v_total<1 or v_total>10000000 then
    raise exception 'Total fora dos limites permitidos.';
  end if;
  update dragons.kiosk_orders set total_cents=v_total::integer where id=v_id;
  return jsonb_build_object('order_id',v_id,'total_cents',v_total,
    'status','awaiting_payment','duplicate',false);
end $$;

-- Registrar a order criada NO provedor. Nao altera o status de preparo.
create or replace function public.kiosk_register_payment(
  p_order_id uuid, p_provider_order_id text, p_method text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order dragons.kiosk_orders; v_attempt dragons.kiosk_payment_attempts;
begin
  if p_method not in ('pix','card') or p_provider_order_id is null or
     length(p_provider_order_id) not between 1 and 128 then
    raise exception 'Referencia de pagamento invalida.';
  end if;
  select * into v_order from dragons.kiosk_orders where id=p_order_id for update;
  if not found or v_order.status<>'awaiting_payment' then
    raise exception 'Pedido nao esta aguardando pagamento.';
  end if;
  select * into v_attempt from dragons.kiosk_payment_attempts
    where order_id=p_order_id and status='pending';
  if found then
    if v_attempt.provider_order_id<>p_provider_order_id or v_attempt.method<>p_method then
      raise exception 'Ja existe um pagamento pendente para este pedido.';
    end if;
    return jsonb_build_object('payment_id',v_attempt.id,'duplicate',true);
  end if;
  insert into dragons.kiosk_payment_attempts(order_id,provider_order_id,method)
    values(p_order_id,p_provider_order_id,p_method)
    returning * into v_attempt;
  return jsonb_build_object('payment_id',v_attempt.id,'duplicate',false);
end $$;

-- Chamado SOMENTE depois da verificacao servidor-a-servidor da order no Mercado Pago.
-- O cliente ou o webhook nao validado nunca podem chamar esta funcao.
create or replace function public.kiosk_approve_verified_payment(
  p_provider_order_id text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_order dragons.kiosk_orders;
  v_attempt dragons.kiosk_payment_attempts;
  v_order_id uuid;
  v_day date;
  v_ticket integer;
  v_section dragons.kiosk_sections;
  v_items jsonb;
begin
  select order_id into v_order_id from dragons.kiosk_payment_attempts
    where provider='mercadopago' and provider_order_id=p_provider_order_id;
  if v_order_id is null then raise exception 'Cobranca nao encontrada.'; end if;
  select * into v_order from dragons.kiosk_orders where id=v_order_id for update;
  select * into v_attempt from dragons.kiosk_payment_attempts
    where provider='mercadopago' and provider_order_id=p_provider_order_id for update;
  if v_attempt.status='approved' then
    return jsonb_build_object('order_id',v_order.id,'status',v_order.status,
      'ticket_number',v_order.ticket_number,'duplicate',true);
  end if;
  if v_attempt.status<>'pending' or v_order.status<>'awaiting_payment' then
    raise exception 'Cobranca ou pedido nao permite aprovacao.';
  end if;
  v_day := (now() at time zone 'America/Campo_Grande')::date;
  insert into dragons.kiosk_daily_counters(ticket_day,last_number)
    values(v_day,1)
    on conflict(ticket_day) do update
      set last_number=dragons.kiosk_daily_counters.last_number+1
    returning last_number into v_ticket;
  if v_ticket>9999 then raise exception 'Numeracao diaria esgotada.'; end if;
  update dragons.kiosk_payment_attempts set status='approved',updated_at=now()
    where id=v_attempt.id;
  update dragons.kiosk_orders set
    status='preparing', paid_at=now(), payment_method=v_attempt.method,
    ticket_day=v_day, ticket_number=v_ticket
    where id=v_order_id;
  insert into dragons.kiosk_sections(order_id,station)
    select distinct v_order_id,station from dragons.kiosk_items where order_id=v_order_id
    on conflict(order_id,station) do nothing;
  for v_section in select * from dragons.kiosk_sections where order_id=v_order_id loop
    select jsonb_agg(jsonb_build_object(
      'product',product_name,'quantity',quantity,'note',note) order by product_name)
      into v_items from dragons.kiosk_items
      where order_id=v_order_id and station=v_section.station;
    insert into dragons.kiosk_print_jobs(order_id,station,payload) values(
      v_order_id,v_section.station,jsonb_build_object(
        'ticket',lpad(v_ticket::text,4,'0'),'ticket_day',v_day,
        'order_id',v_order_id,'station',v_section.station,
        'scan_code',v_section.scan_code,'items',v_items))
      on conflict(order_id,station) do nothing;
  end loop;
  return jsonb_build_object('order_id',v_order_id,'status','preparing',
    'ticket_number',v_ticket,'ticket_day',v_day,'duplicate',false);
end $$;

-- Cada leitura corresponde a uma parte efetivamente entregue ao balcao.
-- A senha so e enfileirada quando todas as partes foram lidas.
create or replace function public.kiosk_scan_section(p_scan_code uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_order_id uuid;
  v_order dragons.kiosk_orders;
  v_section dragons.kiosk_sections;
  v_complete boolean;
  v_duplicate boolean;
begin
  select order_id into v_order_id from dragons.kiosk_sections where scan_code=p_scan_code;
  if v_order_id is null then raise exception 'Codigo nao reconhecido.'; end if;
  select * into v_order from dragons.kiosk_orders where id=v_order_id for update;
  select * into v_section from dragons.kiosk_sections
    where scan_code=p_scan_code for update;
  if v_order.status not in ('preparing','ready','delivered') then
    raise exception 'Pedido nao esta em preparo.';
  end if;
  v_duplicate := v_section.received_at is not null;
  if not v_duplicate then
    update dragons.kiosk_sections set received_at=now()
      where order_id=v_section.order_id and station=v_section.station;
  end if;
  select not exists (
    select 1 from dragons.kiosk_sections
    where order_id=v_order_id and received_at is null) into v_complete;
  if v_complete and v_order.status='preparing' then
    update dragons.kiosk_orders set status='ready',ready_at=now() where id=v_order_id;
    insert into dragons.kiosk_calls(order_id) values(v_order_id)
      on conflict(order_id) do nothing;
  end if;
  return jsonb_build_object('order_id',v_order_id,'station',v_section.station,
    'complete',v_complete,'duplicate',v_duplicate,
    'status',case when v_complete and v_order.status='preparing'
                  then 'ready' else v_order.status end,
    'ticket_number',v_order.ticket_number);
end $$;

-- Agente de impressao local: consulta tarefas com lease, sem perder o ticket
-- se o mini-PC cair antes de confirmar o envio.
create or replace function public.kiosk_claim_print_jobs(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb;
begin
  if p_limit not between 1 and 20 then raise exception 'Limite invalido.'; end if;
  with selected as (
    select id from dragons.kiosk_print_jobs
    where (status='pending' or (status='leased' and lease_until<now()))
      and attempts<10
    order by created_at,id
    for update skip locked limit p_limit
  ), updated as (
    update dragons.kiosk_print_jobs j
       set status='leased',lease_until=now()+interval '90 seconds',attempts=attempts+1
    from selected s where j.id=s.id
    returning j.id,j.order_id,j.station,j.payload,j.attempts
  )
  select coalesce(jsonb_agg(to_jsonb(updated)),'[]'::jsonb)
    into v_result from updated;
  return v_result;
end $$;

create or replace function public.kiosk_ack_print_job(p_job_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_found boolean;
begin
  update dragons.kiosk_print_jobs
    set status='printed',printed_at=coalesce(printed_at,now()),lease_until=null
    where id=p_job_id and status in ('leased','printed')
    returning true into v_found;
  return coalesce(v_found,false);
end $$;

-- Leitura minima para telas de estado e adaptador do letreiro.
create or replace function public.kiosk_order_status(p_order_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('order_id',id,'status',status,
    'ticket_number',ticket_number,'ticket_day',ticket_day,
    'total_cents',total_cents)
  from dragons.kiosk_orders where id=p_order_id
$$;

create or replace function public.kiosk_queued_calls(p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
  if p_limit not between 1 and 50 then raise exception 'Limite invalido.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'call_id',q.id,'order_id',q.order_id,'ticket_number',o.ticket_number,
    'ticket_day',o.ticket_day,'created_at',q.created_at)
    order by q.created_at),'[]'::jsonb) into v_result
  from (select * from dragons.kiosk_calls where status='queued'
        order by created_at limit p_limit) q
  join dragons.kiosk_orders o on o.id=q.order_id;
  return v_result;
end $$;

create or replace function public.kiosk_ack_call(p_call_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_found boolean;
begin
  update dragons.kiosk_calls set status='announced',
    announced_at=coalesce(announced_at,now())
    where id=p_call_id and status in ('queued','announced')
    returning true into v_found;
  return coalesce(v_found,false);
end $$;

-- Nao conceder RPCs ao navegador nem a clientes autenticados.
revoke all on function public.kiosk_create_order(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.kiosk_register_payment(uuid,text,text) from public,anon,authenticated;
revoke all on function public.kiosk_approve_verified_payment(text) from public,anon,authenticated;
revoke all on function public.kiosk_scan_section(uuid) from public,anon,authenticated;
revoke all on function public.kiosk_claim_print_jobs(integer) from public,anon,authenticated;
revoke all on function public.kiosk_ack_print_job(uuid) from public,anon,authenticated;
revoke all on function public.kiosk_order_status(uuid) from public,anon,authenticated;
revoke all on function public.kiosk_queued_calls(integer) from public,anon,authenticated;
revoke all on function public.kiosk_ack_call(uuid) from public,anon,authenticated;

grant execute on function public.kiosk_create_order(text,uuid,jsonb) to service_role;
grant execute on function public.kiosk_register_payment(uuid,text,text) to service_role;
grant execute on function public.kiosk_approve_verified_payment(text) to service_role;
grant execute on function public.kiosk_scan_section(uuid) to service_role;
grant execute on function public.kiosk_claim_print_jobs(integer) to service_role;
grant execute on function public.kiosk_ack_print_job(uuid) to service_role;
grant execute on function public.kiosk_order_status(uuid) to service_role;
grant execute on function public.kiosk_queued_calls(integer) to service_role;
grant execute on function public.kiosk_ack_call(uuid) to service_role;

-- Cardapio publico de leitura restrita ao backend. Nunca expor a service_role ao totem.
create or replace function public.kiosk_public_catalog()
returns jsonb language sql stable security definer set search_path='' as $
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'name',p.name,'description',p.description,'category',p.category,
   'station',p.station,'price_cents',p.price_cents,'image',p.image)
   order by p.category,p.name),'[]'::jsonb)
 from dragons.products p where p.active
$;
revoke all on function public.kiosk_public_catalog() from public,anon,authenticated;
grant execute on function public.kiosk_public_catalog() to service_role;

commit;
