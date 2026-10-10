-- Atualização aditiva: execute depois de 04-qr-fixo-clientes.sql.
-- Pode ser repetida. Não altera vendas, QR Codes ou permissões da operação.
begin;
create or replace function public.dashboard_report(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not exists (
   select 1 from dragons.staff where user_id=auth.uid() and active and role in ('admin','cashier')
 ) then raise exception 'Relatório permitido somente para administração e caixa.'; end if;
 if p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
   or p_to<p_from or p_to-p_from>3660 then
   raise exception 'Escolha um período válido de até 10 anos (3661 dias).';
 end if;
 with paid as materialized (
   select p.*, (p.paid_at at time zone 'America/Cuiaba')::date as "day"
   from dragons.payments p
   where p.paid_at >= (p_from::timestamp at time zone 'America/Cuiaba')
     and p.paid_at < ((p_to+1)::timestamp at time zone 'America/Cuiaba')
 ), daily as (
   select "day", sum(amount_cents)::bigint cents, count(*)::integer count from paid group by "day"
 ), products as (
   select i.product_id, i.station,
     (array_agg(i.name order by p.paid_at desc,i.id))[1] name,
     sum(i.quantity)::bigint quantity, sum(i.quantity::bigint*i.unit_cents)::bigint cents
   from paid p join dragons.orders o on o.tab_id=p.tab_id
   join dragons.items i on i.order_id=o.id
   where i.status<>'canceled'
   group by i.product_id,i.station
 ), methods as (
   select method, sum(amount_cents)::bigint cents, count(*)::integer count from paid group by method
 ), recent as (
   select p.id,p.paid_at,p.amount_cents,p.method,t.name tab_name,d.name table_name
   from paid p join dragons.tabs t on t.id=p.tab_id
   join dragons.visits v on v.id=t.visit_id join dragons.tables d on d.id=v.table_id
   order by p.paid_at desc,p.id limit 100
 )
 select jsonb_build_object(
   'from',p_from,'to',p_to,'generated_at',now(),
   'daily',coalesce((select jsonb_agg(to_jsonb(d) order by "day") from daily d),'[]'::jsonb),
   'products',coalesce((select jsonb_agg(to_jsonb(p) order by quantity desc,cents desc,product_id,station) from products p),'[]'::jsonb),
   'methods',coalesce((select jsonb_agg(to_jsonb(m) order by cents desc,method) from methods m),'[]'::jsonb),
   'payments',coalesce((select jsonb_agg(to_jsonb(r) order by paid_at desc,id) from recent r),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function public.dashboard_report(date,date) from public,anon;
grant execute on function public.dashboard_report(date,date) to authenticated;
notify pgrst,'reload schema';
commit;
