-- Teko backend — run once in Supabase SQL Editor (new/clean project)
create extension if not exists pgcrypto with schema extensions;

create table public.settings(
  id int primary key default 1 check (id = 1),
  lat double precision not null default 29.967067,
  lng double precision not null default 30.9319119,
  radius_m int not null default 564,
  sup_geo boolean not null default true,      -- require supervisor to be at pickup point too
  sup_key_hash text,                          -- sha256 of the supervisor secret key
  ad_text text, ad_url text, ad_until timestamptz
);
insert into public.settings(id) values (1) on conflict do nothing;

create table public.couriers(
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  name text not null check (char_length(name) between 3 and 80),
  phone text not null unique check (phone ~ '^01[0-9]{9}$'),
  created_at timestamptz not null default now()
);

create table public.queue(
  id bigint generated always as identity primary key,
  courier_id uuid not null references public.couriers(id) on delete cascade,
  status text not null default 'waiting' check (status in ('waiting','received')),
  booked_at timestamptz not null default now(),
  sort_at timestamptz not null default clock_timestamp(),
  received_at timestamptz
);
create unique index one_waiting_per_courier on public.queue(courier_id) where status = 'waiting';
create index queue_sort on public.queue(sort_at) where status = 'waiting';

-- Lock all tables: no direct access, everything goes through the RPCs below
alter table public.settings enable row level security;
alter table public.couriers enable row level security;
alter table public.queue enable row level security;
revoke all on public.settings, public.couriers, public.queue from anon, authenticated;

-- ---------- helpers (not callable from the client) ----------
create function public._in_zone(p_lat double precision, p_lng double precision)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_lat is not null and p_lng is not null and
    6371000*2*asin(sqrt(power(sin(radians(p_lat-s.lat)/2),2)
      + cos(radians(s.lat))*cos(radians(p_lat))*power(sin(radians(p_lng-s.lng)/2),2))) <= s.radius_m
  from public.settings s where s.id = 1
$$;

create function public._sup_ok(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p_key,'') <> '' and exists(select 1 from public.settings
    where sup_key_hash = encode(extensions.digest(p_key,'sha256'),'hex'))
$$;

create function public._pub()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'cfg', jsonb_build_object('lat',lat,'lng',lng,'r',radius_m,'geo',sup_geo),
    'ad', case when ad_until > now() and ad_text is not null then
      jsonb_build_object('text',ad_text,'url',ad_url,'end',(extract(epoch from ad_until)*1000)::bigint) end)
  from public.settings where id = 1
$$;

revoke execute on function public._in_zone, public._sup_ok, public._pub from public, anon, authenticated;

-- ---------- courier RPCs ----------
create function public.register(p_name text, p_phone text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare t uuid;
begin
  p_name := left(regexp_replace(trim(p_name), '\s+', ' ', 'g'), 80);
  insert into public.couriers(name, phone) values (p_name, p_phone)
  on conflict (phone) do update set name = excluded.name
  returning token into t;
  return t;
end $$;

create function public.get_state(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c uuid; tot int; pos int; pv text; nx text;
begin
  select id into c from public.couriers where token = p_token;
  if c is null then return jsonb_build_object('err','unknown'); end if;
  with w as (
    select q.courier_id, cr.name, row_number() over (order by q.sort_at, q.id) rn
    from public.queue q join public.couriers cr on cr.id = q.courier_id
    where q.status = 'waiting')
  select (select count(*) from w),
         (select rn from w where courier_id = c),
         (select name from w where rn = (select rn from w where courier_id = c) - 1),
         (select name from w where rn = (select rn from w where courier_id = c) + 1)
  into tot, pos, pv, nx;
  return public._pub() || jsonb_build_object('tot',tot,'pos',coalesce(pos,0),'pv',pv,'nx',nx);
end $$;

create function public.book(p_token uuid, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c uuid;
begin
  select id into c from public.couriers where token = p_token;
  if c is null then return jsonb_build_object('err','unknown'); end if;
  if not public._in_zone(p_lat, p_lng) then return jsonb_build_object('err','outside'); end if;
  insert into public.queue(courier_id) values (c)
  on conflict (courier_id) where status = 'waiting' do nothing;
  return public.get_state(p_token);
end $$;

-- ---------- supervisor RPCs (secret key required) ----------
create function public.sup_state(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public._sup_ok(p_key) then return jsonb_build_object('err','key'); end if;
  return public._pub() || jsonb_build_object('queue', coalesce((
    select jsonb_agg(jsonb_build_object('id',q.id,'name',c.name,'phone',c.phone,
             'booked_at',q.booked_at,'sort_at',q.sort_at) order by q.sort_at, q.id)
    from public.queue q join public.couriers c on c.id = q.courier_id
    where q.status = 'waiting'), '[]'::jsonb));
end $$;

create function public._sup_guard(p_key text, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public._sup_ok(p_key) then raise exception 'forbidden'; end if;
  if (select sup_geo from public.settings where id = 1) and not public._in_zone(p_lat, p_lng) then
    raise exception 'outside';
  end if;
end $$;
revoke execute on function public._sup_guard from public, anon, authenticated;

create function public.sup_receive(p_key text, p_id bigint, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._sup_guard(p_key, p_lat, p_lng);
  update public.queue set status = 'received', received_at = now() where id = p_id and status = 'waiting';
end $$;

create function public.sup_postpone(p_key text, p_id bigint, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._sup_guard(p_key, p_lat, p_lng);
  update public.queue set sort_at = clock_timestamp() where id = p_id and status = 'waiting';
end $$;

create function public.sup_undo(p_key text, p_id bigint, p_sort timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public._sup_ok(p_key) then raise exception 'forbidden'; end if;
  update public.queue set status = 'waiting', received_at = null, sort_at = p_sort
  where id = p_id and not exists (select 1 from public.queue x
                                  where x.courier_id = queue.courier_id and x.status = 'waiting' and x.id <> queue.id);
end $$;

grant execute on function public.register, public.get_state, public.book,
  public.sup_state, public.sup_receive, public.sup_postpone, public.sup_undo to anon;

-- ---------- realtime ping (clients refetch on ping; they also poll every 4s) ----------
create function public._ping() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin perform realtime.send('{}'::jsonb, 'q', 'teko', false); exception when others then null; end;
  return null;
end $$;
create trigger queue_ping after insert or update or delete on public.queue
  for each statement execute function public._ping();

-- ---------- ADMIN (run manually, edit values) ----------
-- 1) supervisor secret key (use a long random string; supervisor link = .../supervisor.html#k=THE_KEY)
-- update public.settings set sup_key_hash = encode(extensions.digest('PUT_LONG_RANDOM_KEY','sha256'),'hex') where id = 1;
-- 2) pickup location + radius (meters)
-- update public.settings set lat = 29.967067, lng = 30.9319119, radius_m = 564 where id = 1;
-- 3) run an ad for 7 days (clear with ad_until = null)
-- update public.settings set ad_text = 'نص الإعلان', ad_url = 'https://wa.me/201XXXXXXXXX', ad_until = now() + interval '7 days' where id = 1;
