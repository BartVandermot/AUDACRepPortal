-- Deals: location, registration type, BOM and an approximate dealer value (2026-11-19).
--
-- Dynamics' estimated value on NA opportunities is AVL's purchase value in EUR
-- (calculated by the PVS Portal), not something a rep recognises. Reps now see
-- an approximate dealer value instead: BOM quantity x the AVL U.S. dealer price
-- list (July V7.0). The EUR value stays in value_usd (name kept for the
-- dashboards) and is labelled as EUR for managers.
--
-- Applied via execute_sql in parts (apply_migration and DROP/DELETE are
-- auto-declined in the desktop session): the old get_my_deals() was renamed
-- to get_my_deals_superseded_0070 instead of dropped, and a new price list
-- deactivates the old rows (active = false) instead of deleting them.
-- Price list July V7.0 (354 SKUs) was seeded separately from AVL's Excel.

alter table public.pipeline_entries
  add column if not exists location text,
  add column if not exists opportunity_type text,
  add column if not exists origin text,
  add column if not exists vertical text,
  add column if not exists bom_lines integer not null default 0,
  add column if not exists dealer_value_usd numeric,
  add column if not exists dealer_value_missing integer not null default 0;

-- One row per Dynamics opportunity product line.
create table if not exists public.pipeline_entry_products (
  line_id text primary key,
  crm_id text not null references public.pipeline_entries(crm_id) on delete cascade,
  product_number text,
  product_name text,
  quantity numeric not null default 0,
  synced_at timestamptz not null default now()
);
create index if not exists pipeline_entry_products_crm_idx on public.pipeline_entry_products(crm_id);
alter table public.pipeline_entry_products enable row level security;
create policy pipeline_entry_products_mgr_read on public.pipeline_entry_products
  for select to authenticated using (public.current_role_name() in ('manager', 'executive'));

-- AVL U.S. dealer price list. sku = Dynamics product number (AVL SKU without "ADC-").
-- per_pair: the list price is for a pair ("priced & sold per pair"); a BOM
-- quantity counts pieces, so the piece price is half.
create table if not exists public.avl_dealer_prices (
  sku text primary key,
  dealer_usd numeric not null,
  msrp_usd numeric,
  per_pair boolean not null default false,
  price_list text not null,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.avl_dealer_prices enable row level security;
create policy avl_dealer_prices_read on public.avl_dealer_prices
  for select to authenticated using (true);

-- European product numbers that exist in the U.S. list under another SKU.
create table if not exists public.avl_sku_aliases (
  from_sku text primary key,
  to_sku text not null
);
alter table public.avl_sku_aliases enable row level security;
create policy avl_sku_aliases_read on public.avl_sku_aliases
  for select to authenticated using (true);
insert into public.avl_sku_aliases (from_sku, to_sku) values
  ('VEXO208/B', 'VEXO208I/B'), ('VEXO208/W', 'VEXO208I/W'),
  ('WP205/B', 'WP205US/B'), ('WP205/W', 'WP205US/W'),
  ('WP210/B', 'WP210US/B'), ('WP210/W', 'WP210US/W'),
  ('WP220/B', 'WP220US/B'), ('WP220/W', 'WP220US/W'),
  ('WP225/B', 'WP225US/B'), ('WP225/W', 'WP225US/W'),
  ('WP200/B', 'WP200US/B'), ('WP200/W', 'WP200US/W')
on conflict (from_sku) do update set to_sku = excluded.to_sku;

-- Dealer price of one piece, or null when the SKU is not on the U.S. list.
create or replace function public.avl_piece_price(p_sku text)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when d.per_pair then d.dealer_usd / 2 else d.dealer_usd end
    from public.avl_dealer_prices d
   where d.active
     and d.sku = coalesce((select a.to_sku from public.avl_sku_aliases a where a.from_sku = upper(trim(p_sku))), upper(trim(p_sku)));
$$;
revoke all on function public.avl_piece_price(text) from public, anon;
grant execute on function public.avl_piece_price(text) to authenticated;

-- Recalculate bom_lines / dealer_value_usd / dealer_value_missing.
-- p_crm_ids null = every synced deal. Callable by the sync (service role) and managers.
create or replace function public.refresh_dealer_values(p_crm_ids text[] default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  if auth.uid() is not null and public.current_role_name() is distinct from 'manager' then
    raise exception 'Only a manager can recalculate dealer values';
  end if;
  with x as (
    select p.crm_id,
           count(l.line_id)::int as lines,
           sum(l.quantity * public.avl_piece_price(l.product_number)) as val,
           count(l.line_id) filter (where public.avl_piece_price(l.product_number) is null)::int as missing
      from public.pipeline_entries p
      left join public.pipeline_entry_products l on l.crm_id = p.crm_id
     where p.crm_id is not null and (p_crm_ids is null or p.crm_id = any(p_crm_ids))
     group by p.crm_id
  )
  update public.pipeline_entries p
     set bom_lines = x.lines,
         dealer_value_usd = case when x.lines > 0 then round(coalesce(x.val, 0), 2) end,
         dealer_value_missing = x.missing
    from x
   where p.crm_id = x.crm_id;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.refresh_dealer_values(text[]) from public, anon;
grant execute on function public.refresh_dealer_values(text[]) to authenticated, service_role;

-- Replace the whole price list (Data Admin upload). p_rows: [{sku, dealer, msrp, per_pair}].
create or replace function public.replace_avl_dealer_prices(p_price_list text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  if public.current_role_name() is distinct from 'manager' then
    raise exception 'Only a manager can upload the dealer price list';
  end if;
  if p_price_list is null or length(trim(p_price_list)) = 0 then raise exception 'Name the price list version'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 10 then
    raise exception 'The file did not contain a usable price list';
  end if;
  -- A new list replaces the old one: SKUs that are not on it stop counting.
  update public.avl_dealer_prices set active = false where active;
  insert into public.avl_dealer_prices (sku, dealer_usd, msrp_usd, per_pair, price_list, active, updated_at)
  select distinct on (upper(trim(r->>'sku')))
         upper(trim(r->>'sku')), (r->>'dealer')::numeric, nullif(r->>'msrp', '')::numeric,
         coalesce((r->>'per_pair')::boolean, false), trim(p_price_list), true, now()
    from jsonb_array_elements(p_rows) r
   where nullif(trim(r->>'sku'), '') is not null and (r->>'dealer') ~ '^[0-9]+(\.[0-9]+)?$'
  on conflict (sku) do update set dealer_usd = excluded.dealer_usd, msrp_usd = excluded.msrp_usd,
     per_pair = excluded.per_pair, price_list = excluded.price_list, active = true, updated_at = now();
  get diagnostics n = row_count;
  perform public.refresh_dealer_values(null);
  return n;
end;
$$;
revoke all on function public.replace_avl_dealer_prices(text, jsonb) from public, anon;
grant execute on function public.replace_avl_dealer_prices(text, jsonb) to authenticated;

-- Reps: deals with dealer, location, registration type, BOM and dealer value.
-- AVL's EUR purchase value is no longer returned to reps.
alter function public.get_my_deals() rename to get_my_deals_superseded_0070;
revoke all on function public.get_my_deals_superseded_0070() from public, anon, authenticated;
create function public.get_my_deals()
returns table(crm_id text, project_name text, account_name text, location text, status text, stage text,
              opportunity_type text, dealer_value_usd numeric, dealer_value_missing integer, bom jsonb,
              created_date date, expected_close_date date, actual_close_date date,
              pending_status text, pending_close_date date, pending_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.crm_id, p.project_name, p.account_name, p.location, p.status, p.stage,
         p.opportunity_type, p.dealer_value_usd, p.dealer_value_missing,
         coalesce((select jsonb_agg(jsonb_build_object('sku', l.product_number, 'name', l.product_name, 'qty', l.quantity)
                                    order by l.product_number)
                     from public.pipeline_entry_products l where l.crm_id = p.crm_id), '[]'::jsonb),
         p.created_date, p.expected_close_date, p.actual_close_date,
         u.proposed_status, u.proposed_close_date, u.created_at
    from public.pipeline_entries p
    left join lateral (
      select d.proposed_status, d.proposed_close_date, d.created_at
        from public.deal_status_updates d
       where d.crm_id = p.crm_id and d.handled_at is null
       order by d.created_at desc limit 1
    ) u on true
   where p.rep_firm_id = public.my_rep_firm_id() and p.crm_id is not null
   order by (p.status = 'Open') desc, p.expected_close_date nulls last, p.created_date desc;
$function$;
revoke all on function public.get_my_deals() from public, anon;
grant execute on function public.get_my_deals() to authenticated;

-- My territory: an account's open deals carry the dealer value, not AVL's EUR value.
create or replace function public.get_my_territory()
 returns table(external_id text, name text, street text, city text, state_code text, zip text, phone text, website text, relationship_type text, business_type text, key_reason text, added_by_firm boolean, last_logged date, logged_count integer, contacts jsonb, open_deals jsonb)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select a.external_id, a.name, a.street, a.city, a.state_code, a.zip, a.phone, a.website,
         a.relationship_type, a.business_type,
         case when a.classification = 'TOP AUDAC LEAD' then 'Top lead'
              when a.audac_partner_type ~* 'AUDAC\s+(Certified\s+)?(Partner|Distributor)' then trim(a.audac_partner_type) end,
         a.source = 'manual',
         (select max(e.entry_date) from public.activity_entries e where e.account_external_id = a.external_id and e.rep_firm_id = a.rep_firm_id),
         (select count(*)::int from public.activity_entries e where e.account_external_id = a.external_id and e.rep_firm_id = a.rep_firm_id),
         coalesce((select jsonb_agg(jsonb_build_object('id', c.external_id, 'name', c.full_name, 'email', c.email, 'phone', c.phone) order by c.full_name)
                     from public.crm_contacts c where c.parent_account_external_id = a.external_id and c.is_active), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('crm_id', p.crm_id, 'name', p.project_name, 'value', p.dealer_value_usd, 'close', p.expected_close_date) order by p.expected_close_date nulls last)
                     from public.pipeline_entries p where p.account_external_id = a.external_id and p.rep_firm_id = a.rep_firm_id and p.status = 'Open'), '[]'::jsonb)
    from public.crm_accounts a
   where a.rep_firm_id = public.my_rep_firm_id()
     and a.is_active
     and not public.crm_hidden_from_reps(a.relationship_type, a.business_type)
     and not exists (select 1 from public.rep_firms f where f.crm_account_external_id = a.external_id)
   order by a.name;
$function$;

-- Manager forecast: product quantities in open deals by expected close month.
create or replace function public.get_product_forecast()
returns table(sku text, product_name text, close_month text, quantity numeric, deals integer, dealer_value_usd numeric, registered boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select l.product_number, max(l.product_name),
         coalesce(to_char(p.expected_close_date, 'YYYY-MM'), 'no date'),
         sum(l.quantity), count(distinct p.crm_id)::int,
         round(sum(l.quantity * public.avl_piece_price(l.product_number)), 2),
         bool_and(p.opportunity_type = 'Registered Project')
    from public.pipeline_entries p
    join public.pipeline_entry_products l on l.crm_id = p.crm_id
   where p.status = 'Open'
     and public.current_role_name() in ('manager', 'executive')
   group by l.product_number, coalesce(to_char(p.expected_close_date, 'YYYY-MM'), 'no date');
$$;
revoke all on function public.get_product_forecast() from public, anon;
grant execute on function public.get_product_forecast() to authenticated;
