-- 1. Crie o usuário em Authentication > Users > Add user > Create new user.
-- 2. Informe email, senha e marque Auto Confirm User.
-- 3. Substitua SOMENTE o e-mail e nome abaixo pelos seus dados reais.
-- 4. Execute este script no SQL Editor. Ele NÃO cria usuários de autenticação.
do $$
declare
  admin_email text := 'SEU_EMAIL_AQUI';
  admin_name text := 'SEU_NOME_AQUI';
  admin_id uuid;
begin
  select id into admin_id from auth.users where lower(email)=lower(admin_email) and coalesce(is_anonymous,false)=false;
  if admin_id is null then
    raise exception 'Usuário não encontrado. Crie primeiro em Authentication > Users e confira o e-mail neste script.';
  end if;
  insert into dragons.staff(user_id,name,role,active) values(admin_id,admin_name,'admin',true)
  on conflict(user_id) do update set name=excluded.name,role='admin',active=true;
  raise notice 'Administrador vinculado com sucesso.';
end $$;
