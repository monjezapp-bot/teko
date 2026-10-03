-- Teko — دومينو طيار ضد طيار (Supabase SQL Editor — شغّله مرة واحدة، مش بيلمس الجداول القديمة)
-- السيرفر هو الحكم: بيوزع الأحجار، بيتحقق من كل حركة، وكل طيار بيشوف إيده هو بس.

create table if not exists public.dm_lobby(
  courier_id uuid primary key references public.couriers(id) on delete cascade,
  seen_at timestamptz not null default now());

create table if not exists public.dm_stats(
  courier_id uuid primary key references public.couriers(id) on delete cascade,
  wins int not null default 0, games int not null default 0);

create table if not exists public.dm_games(
  id bigint generated always as identity primary key,
  p1 uuid not null references public.couriers(id) on delete cascade,
  p2 uuid not null references public.couriers(id) on delete cascade,
  hand1 jsonb not null, hand2 jsonb not null, stock jsonb not null,
  chain jsonb not null default '[]', ends jsonb,
  turn smallint not null default 1, passes smallint not null default 0,
  first_key text not null,
  status text not null default 'active' check (status in ('active','over')),
  res_who smallint, res_pts int, res_why text,
  last_by smallint, last_tile jsonb,
  ack1 boolean not null default false, ack2 boolean not null default false,
  ver int not null default 0,
  moved_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (p1 <> p2));
create index if not exists dm_games_p1 on public.dm_games(p1, id desc);
create index if not exists dm_games_p2 on public.dm_games(p2, id desc);

alter table public.dm_lobby add column if not exists code text;  -- null = لعب عشوائي، غير كده = غرفة خاصة بكود
alter table public.dm_lobby enable row level security;
alter table public.dm_stats enable row level security;
alter table public.dm_games enable row level security;
revoke all on public.dm_lobby, public.dm_stats, public.dm_games from anon, authenticated;

-- ---------- helpers ----------
create or replace function public._dm_score(t jsonb) returns int
language sql immutable set search_path = '' as $$
  select case when (t->>0)::int = (t->>1)::int then 100 + (t->>0)::int else (t->>0)::int + (t->>1)::int end $$;

create or replace function public._dm_sum(h jsonb) returns int
language sql immutable set search_path = '' as $$
  select coalesce(sum((e->>0)::int + (e->>1)::int), 0)::int from jsonb_array_elements(h) e $$;

create or replace function public._dm_key(t jsonb) returns text
language sql immutable set search_path = '' as $$
  select least((t->>0)::int, (t->>1)::int)::text || '-' || greatest((t->>0)::int, (t->>1)::int)::text $$;

create or replace function public._dm_slice(arr jsonb, p_from int, p_cnt int) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(e order by n), '[]'::jsonb)
  from jsonb_array_elements(arr) with ordinality x(e, n) where n > p_from and n <= p_from + p_cnt $$;

create or replace function public._dm_best(h jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select e from jsonb_array_elements(h) e order by public._dm_score(e) desc limit 1 $$;

create or replace function public._dm_sides(ch jsonb, en jsonb, t jsonb, fk text) returns text[]
language plpgsql immutable set search_path = '' as $$
declare a int := (t->>0)::int; b int := (t->>1)::int; s text[] := '{}'; l int; r int;
begin
  if jsonb_array_length(ch) = 0 then
    if public._dm_key(t) = fk then return array['R']; end if;
    return s;
  end if;
  l := (en->>0)::int; r := (en->>1)::int;
  if a = l or b = l then s := s || 'L'::text; end if;
  if a = r or b = r then s := s || 'R'::text; end if;
  if cardinality(s) = 2 and l = r then return array['R']; end if;
  return s;
end $$;

create or replace function public._dm_has_move(h jsonb, ch jsonb, en jsonb, fk text) returns boolean
language sql immutable set search_path = '' as $$
  select exists(select 1 from jsonb_array_elements(h) e where cardinality(public._dm_sides(ch, en, e, fk)) > 0) $$;

-- نتيجة القفلة: who = 1 / 2 / 0 (تعادل)
create or replace function public._dm_block(h1 jsonb, h2 jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case when public._dm_sum(h1) < public._dm_sum(h2) then jsonb_build_object('who',1,'pts',public._dm_sum(h2)-public._dm_sum(h1))
              when public._dm_sum(h2) < public._dm_sum(h1) then jsonb_build_object('who',2,'pts',public._dm_sum(h1)-public._dm_sum(h2))
              else jsonb_build_object('who',0,'pts',0) end $$;

create or replace function public._dm_end(p_game bigint, p_who int, p_pts int, p_why text) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.dm_games%rowtype;
begin
  select * into g from public.dm_games where id = p_game for update;
  if not found or g.status = 'over' then return; end if;
  update public.dm_games set status = 'over', res_who = p_who, res_pts = p_pts, res_why = p_why,
    ver = ver + 1, moved_at = now() where id = p_game;
  insert into public.dm_stats(courier_id, wins, games) values (g.p1, case when p_who = 1 then 1 else 0 end, 1)
    on conflict (courier_id) do update set games = public.dm_stats.games + 1, wins = public.dm_stats.wins + excluded.wins;
  insert into public.dm_stats(courier_id, wins, games) values (g.p2, case when p_who = 2 then 1 else 0 end, 1)
    on conflict (courier_id) do update set games = public.dm_stats.games + 1, wins = public.dm_stats.wins + excluded.wins;
end $$;

create or replace function public._dm_view(g public.dm_games, s int) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', g.id, 'seat', s,
    'opp', (select split_part(name, ' ', 1) from public.couriers where id = case when s = 1 then g.p2 else g.p1 end),
    'my', case when s = 1 then g.hand1 else g.hand2 end,
    'opp_n', jsonb_array_length(case when s = 1 then g.hand2 else g.hand1 end),
    'stock_n', jsonb_array_length(g.stock),
    'chain', g.chain, 'ends', g.ends, 'mine', g.turn = s, 'passes', g.passes, 'fk', g.first_key,
    'over', case when g.status = 'over' then jsonb_build_object(
        'who', case when g.res_who = 0 then 'tie' when g.res_who = s then 'me' else 'opp' end,
        'pts', g.res_pts, 'why', g.res_why) end,
    'last_by', case when g.last_by is null then null when g.last_by = s then 'me' else 'opp' end,
    'last', g.last_tile, 'ver', g.ver,
    'idle', extract(epoch from (now() - g.moved_at))::int) $$;

-- ---------- RPCs ----------
create or replace function public.dm_state(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c uuid; g public.dm_games%rowtype; inl boolean; v jsonb;
begin
  select id into c from public.couriers where token = p_token;
  if c is null then return jsonb_build_object('err','unknown'); end if;
  update public.dm_lobby set seen_at = now() where courier_id = c;
  inl := exists(select 1 from public.dm_lobby where courier_id = c);
  select * into g from public.dm_games
   where (p1 = c and (status = 'active' or not ack1)) or (p2 = c and (status = 'active' or not ack2))
   order by id desc limit 1;
  if found then v := public._dm_view(g, case when g.p1 = c then 1 else 2 end); end if;
  return jsonb_build_object(
    'lobby', (select count(*) from public.dm_lobby where courier_id <> c and code is null and seen_at > now() - interval '20 seconds'),
    'wait', inl,
    'wins', coalesce((select wins from public.dm_stats where courier_id = c), 0),
    'game', v);
end $$;

drop function if exists public.dm_find(uuid);
create or replace function public.dm_find(p_token uuid, p_code text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c uuid; o uuid; allt jsonb; h1 jsonb; h2 jsonb; b1 jsonb; b2 jsonb; t int; fk text;
begin
  select id into c from public.couriers where token = p_token;
  if c is null then return jsonb_build_object('err','unknown'); end if;
  if exists(select 1 from public.dm_games where status = 'active' and (p1 = c or p2 = c)) then
    return public.dm_state(p_token);
  end if;
  delete from public.dm_lobby where seen_at < now() - interval '20 seconds';
  p_code := nullif(left(regexp_replace(coalesce(p_code,''), '[^0-9]', '', 'g'), 4), '');
  select courier_id into o from public.dm_lobby where courier_id <> c and code is not distinct from p_code order by seen_at limit 1 for update skip locked;
  if o is null then
    insert into public.dm_lobby(courier_id, code) values (c, p_code) on conflict (courier_id) do update set seen_at = now(), code = excluded.code;
  else
    delete from public.dm_lobby where courier_id in (c, o);
    select jsonb_agg(jsonb_build_array(i, j) order by random()) into allt
      from generate_series(0,6) i, generate_series(0,6) j where j >= i;
    h1 := public._dm_slice(allt, 0, 7); h2 := public._dm_slice(allt, 7, 7);
    b1 := public._dm_best(h1); b2 := public._dm_best(h2);
    if public._dm_score(b1) >= public._dm_score(b2) then t := 1; fk := public._dm_key(b1); else t := 2; fk := public._dm_key(b2); end if;
    insert into public.dm_games(p1, p2, hand1, hand2, stock, turn, first_key)
      values (o, c, h1, h2, public._dm_slice(allt, 14, 14), t, fk);
  end if;
  return public.dm_state(p_token);
end $$;

create or replace function public.dm_cancel(p_token uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.dm_lobby where courier_id = (select id from public.couriers where token = p_token);
end $$;

create or replace function public.dm_move(p_token uuid, p_game bigint, p_kind text,
  p_a int default null, p_b int default null, p_side text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c uuid; g public.dm_games%rowtype; s int; me jsonb; op jsonb; ch jsonb; en jsonb; st jsonb;
  t jsonb; o jsonb; idx int; sides text[]; anyl boolean; np int; nt int; lb int; lt jsonb;
  ow int; opts int; owhy text; r jsonb;
begin
  select id into c from public.couriers where token = p_token;
  if c is null then return jsonb_build_object('err','unknown'); end if;
  select * into g from public.dm_games where id = p_game for update;
  if not found then return jsonb_build_object('err','nogame'); end if;
  s := case when g.p1 = c then 1 when g.p2 = c then 2 else 0 end;
  if s = 0 then return jsonb_build_object('err','forbidden'); end if;
  if g.status <> 'active' then return jsonb_build_object('err','over','game',public._dm_view(g, s)); end if;
  if g.turn <> s then return jsonb_build_object('err','turn','game',public._dm_view(g, s)); end if;

  me := case when s = 1 then g.hand1 else g.hand2 end;
  op := case when s = 1 then g.hand2 else g.hand1 end;
  ch := g.chain; en := g.ends; st := g.stock; np := g.passes; nt := g.turn; lb := g.last_by; lt := g.last_tile;
  anyl := public._dm_has_move(me, ch, en, g.first_key);

  if p_kind = 'play' then
    select (n - 1)::int into idx from jsonb_array_elements(me) with ordinality x(e, n)
      where ((e->>0)::int = p_a and (e->>1)::int = p_b) or ((e->>0)::int = p_b and (e->>1)::int = p_a) limit 1;
    if idx is null then return jsonb_build_object('err','tile'); end if;
    t := me -> idx;
    sides := public._dm_sides(ch, en, t, g.first_key);
    if cardinality(sides) = 0 then return jsonb_build_object('err','illegal'); end if;
    if cardinality(sides) = 1 then p_side := sides[1];
    elsif p_side is null or not (p_side = any(sides)) then return jsonb_build_object('err','side'); end if;
    me := me - idx;
    if jsonb_array_length(ch) = 0 then
      o := jsonb_build_array(t->0, t->1); ch := jsonb_build_array(o); en := jsonb_build_array(t->0, t->1);
    elsif p_side = 'R' then
      o := case when t->0 = en->1 then jsonb_build_array(t->0, t->1) else jsonb_build_array(t->1, t->0) end;
      ch := ch || jsonb_build_array(o); en := jsonb_build_array(en->0, o->1);
    else
      o := case when t->1 = en->0 then jsonb_build_array(t->0, t->1) else jsonb_build_array(t->1, t->0) end;
      ch := jsonb_build_array(o) || ch; en := jsonb_build_array(o->0, en->1);
    end if;
    np := 0; lb := s; lt := o;
    if jsonb_array_length(me) = 0 then ow := s; opts := public._dm_sum(op); owhy := 'domino';
    else nt := 3 - s; end if;

  elsif p_kind = 'draw' then
    if anyl or jsonb_array_length(st) = 0 then return jsonb_build_object('err','nodraw'); end if;
    me := me || jsonb_build_array(st -> (jsonb_array_length(st) - 1));
    st := st - (jsonb_array_length(st) - 1);

  elsif p_kind = 'pass' then
    if anyl or jsonb_array_length(st) > 0 then return jsonb_build_object('err','nopass'); end if;
    np := np + 1;
    if np >= 2 then
      r := public._dm_block(case when s = 1 then me else op end, case when s = 1 then op else me end);
      ow := (r->>'who')::int; opts := (r->>'pts')::int; owhy := 'block';
    else nt := 3 - s; end if;
  else
    return jsonb_build_object('err','kind');
  end if;

  update public.dm_games set
    hand1 = case when s = 1 then me else op end, hand2 = case when s = 2 then me else op end,
    stock = st, chain = ch, ends = en, turn = nt, passes = np, last_by = lb, last_tile = lt,
    ver = ver + 1, moved_at = now() where id = g.id;
  if ow is not null then perform public._dm_end(g.id, ow, opts, owhy); end if;
  select * into g from public.dm_games where id = g.id;
  return jsonb_build_object('ok', true, 'game', public._dm_view(g, s));
end $$;

-- الطيار بينسحب
create or replace function public.dm_quit(p_token uuid, p_game bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c uuid; g public.dm_games%rowtype; s int;
begin
  select id into c from public.couriers where token = p_token;
  select * into g from public.dm_games where id = p_game and (p1 = c or p2 = c) for update;
  if not found then return jsonb_build_object('err','nogame'); end if;
  s := case when g.p1 = c then 1 else 2 end;
  if g.status = 'active' then
    perform public._dm_end(g.id, 3 - s, public._dm_sum(case when s = 1 then g.hand1 else g.hand2 end), 'quit');
  end if;
  return public.dm_state(p_token);
end $$;

-- الخصم ما بيردّش أكتر من ٩٠ ثانية
create or replace function public.dm_timeout(p_token uuid, p_game bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c uuid; g public.dm_games%rowtype; s int; idle_h jsonb; r jsonb;
begin
  select id into c from public.couriers where token = p_token;
  select * into g from public.dm_games where id = p_game and (p1 = c or p2 = c) for update;
  if not found or g.status <> 'active' then return public.dm_state(p_token); end if;
  s := case when g.p1 = c then 1 else 2 end;
  if g.turn = s or g.moved_at > now() - interval '90 seconds' then return public.dm_state(p_token); end if;
  idle_h := case when g.turn = 1 then g.hand1 else g.hand2 end;
  if not public._dm_has_move(idle_h, g.chain, g.ends, g.first_key) and jsonb_array_length(g.stock) = 0 then
    -- مفيش قدامه غير يعدّي: السيرفر يعدّي عنه (مش ذنبه)
    if g.passes + 1 >= 2 then
      r := public._dm_block(g.hand1, g.hand2);
      update public.dm_games set passes = g.passes + 1, last_by = g.turn, last_tile = null where id = g.id;
      perform public._dm_end(g.id, (r->>'who')::int, (r->>'pts')::int, 'block');
    else
      update public.dm_games set passes = g.passes + 1, turn = 3 - g.turn, ver = ver + 1, moved_at = now() where id = g.id;
    end if;
  else
    perform public._dm_end(g.id, s, public._dm_sum(idle_h), 'timeout');
  end if;
  return public.dm_state(p_token);
end $$;

create or replace function public.dm_ack(p_token uuid, p_game bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare c uuid;
begin
  select id into c from public.couriers where token = p_token;
  update public.dm_games set ack1 = ack1 or p1 = c, ack2 = ack2 or p2 = c where id = p_game and status = 'over' and (p1 = c or p2 = c);
end $$;

-- ---------- ping لحظي لكل لعبة (والعملاء بيسألوا كل ٣ ثواني كاحتياطي) ----------
create or replace function public._dm_ping() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin perform realtime.send('{}'::jsonb, 'g', 'dm' || new.id::text, false); exception when others then null; end;
  return null;
end $$;
drop trigger if exists dm_games_ping on public.dm_games;
create trigger dm_games_ping after insert or update on public.dm_games for each row execute function public._dm_ping();

revoke execute on function public._dm_score, public._dm_sum, public._dm_key, public._dm_slice, public._dm_best,
  public._dm_sides, public._dm_has_move, public._dm_block, public._dm_end, public._dm_view, public._dm_ping
  from public, anon, authenticated;
grant execute on function public.dm_state, public.dm_find, public.dm_cancel, public.dm_move,
  public.dm_quit, public.dm_timeout, public.dm_ack to anon;
