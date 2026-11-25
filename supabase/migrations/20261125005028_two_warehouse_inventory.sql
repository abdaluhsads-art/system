-- Existing qty continues to represent stock available for sale in the shop.
alter table public.products
  add column main_qty numeric not null default 0 check (main_qty >= 0),
  add column main_damaged_qty numeric not null default 0 check (main_damaged_qty >= 0),
  add column main_worn_qty numeric not null default 0 check (main_worn_qty >= 0),
  add column shop_damaged_qty numeric not null default 0 check (shop_damaged_qty >= 0),
  add column shop_worn_qty numeric not null default 0 check (shop_worn_qty >= 0),
  add constraint products_shop_qty_nonnegative check (qty >= 0);

create table public.stock_movements (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null references public.products(id) on delete cascade,
  action text not null check (action in ('receive', 'transfer', 'damaged', 'worn')),
  warehouse text not null check (warehouse in ('main', 'shop')),
  units numeric not null check (units between 1 and 9007199254740991 and units = trunc(units))
);
create index stock_movements_product_idx on public.stock_movements (product_id);
alter table public.stock_movements enable row level security;
grant select, insert on public.stock_movements to authenticated;
create policy stock_movements_select on public.stock_movements
  for select to authenticated using ((select auth.uid()) = user_id);
create policy stock_movements_insert on public.stock_movements
  for insert to authenticated with check ((select auth.uid()) = user_id);

create function public.move_product_stock(
  p_id text, p_product_id text, p_action text, p_warehouse text, p_units numeric
) returns public.products
language plpgsql security invoker set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  product public.products;
begin
  if p_action is null or p_warehouse is null or p_units is null or
     p_action not in ('receive', 'transfer', 'damaged', 'worn') or
     p_warehouse not in ('main', 'shop') or
     (p_action in ('receive', 'transfer') and p_warehouse <> 'main') or
     p_units not between 1 and 9007199254740991 or p_units <> trunc(p_units) then
    raise exception 'أدخل عدداً صحيحاً من القطع';
  end if;

  select * into product from public.products
  where id = p_product_id and user_id = owner_id for update;
  if not found then raise exception 'الصنف غير موجود'; end if;

  insert into public.stock_movements (id, user_id, product_id, action, warehouse, units)
  values (p_id, owner_id, p_product_id, p_action, p_warehouse, p_units)
  on conflict (id) do nothing;
  if not found then
    if not exists (
      select 1 from public.stock_movements
      where id = p_id and user_id = owner_id and product_id = p_product_id
        and action = p_action and warehouse = p_warehouse and units = p_units
    ) then
      raise exception 'تغيّرت بيانات الحركة. ارجع للصنف وحاول مرة ثانية';
    end if;
    return product;
  end if;

  if p_action <> 'receive' and p_units > (case p_warehouse
      when 'main' then product.main_qty else product.qty end) then
    raise exception 'الكمية المطلوبة أكبر من الرصيد السليم بالمخزن';
  end if;

  update public.products
  set main_qty = main_qty + case
        when p_action = 'receive' then p_units when p_warehouse = 'main' then -p_units else 0 end,
      qty = qty + case
        when p_action = 'transfer' then p_units when p_warehouse = 'shop' then -p_units else 0 end,
      main_damaged_qty = main_damaged_qty + case when p_action = 'damaged' and p_warehouse = 'main' then p_units else 0 end,
      main_worn_qty = main_worn_qty + case when p_action = 'worn' and p_warehouse = 'main' then p_units else 0 end,
      shop_damaged_qty = shop_damaged_qty + case when p_action = 'damaged' and p_warehouse = 'shop' then p_units else 0 end,
      shop_worn_qty = shop_worn_qty + case when p_action = 'worn' and p_warehouse = 'shop' then p_units else 0 end
  where id = p_product_id and user_id = owner_id returning * into product;
  return product;
end;
$$;

-- Stock, invoice lines and the payment at sale time commit together.
create function public.save_inventory_sale(
  p_id text, p_editing boolean, p_customer_id text, p_date timestamptz,
  p_discount numeric, p_paid numeric, p_items jsonb
) returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  invoice public.sales;
  line record;
  updated_product public.products;
  affected jsonb := '[]'::jsonb;
  product_ids text[];
  invoice_total numeric;
  applied_paid numeric;
  sale_already_saved boolean;
begin
  if owner_id is null then raise exception 'سجّل الدخول أولاً'; end if;
  if p_date is null or p_discount is null or p_paid is null or
     p_discount < 0 or p_paid < 0 or p_discount >= 'Infinity'::numeric or p_paid >= 'Infinity'::numeric then
    raise exception 'راجع تاريخ الفاتورة والمبالغ';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'أضف أصناف للفاتورة'; end if;
  if jsonb_array_length(p_items) = 0 or exists (
    select 1 from jsonb_to_recordset(p_items) as i(product_id text, units numeric)
    where i.product_id is null or i.units is null or i.units not between 1 and 9007199254740991 or i.units <> trunc(i.units)
  ) then
    raise exception 'راجع كميات الأصناف';
  end if;
  if p_customer_id is not null and not exists (
    select 1 from public.customers where id = p_customer_id and user_id = owner_id
  ) then raise exception 'العميل غير موجود'; end if;

  if not p_editing then
    insert into public.sales (id, user_id, customer_id, date)
    values (p_id, owner_id, p_customer_id, p_date)
    on conflict (id) do nothing;
    sale_already_saved := not found;
  end if;
  select * into invoice from public.sales where id = p_id and user_id = owner_id for update;
  if not found then raise exception 'الفاتورة غير موجودة'; end if;

  if not coalesce(sale_already_saved, false) then
    if exists (
      select 1 from jsonb_to_recordset(p_items) as i(product_id text, units numeric)
      where not exists (select 1 from public.products p where p.id = i.product_id and p.user_id = owner_id)
    ) then raise exception 'أحد الأصناف غير موجود بالمخزون'; end if;

    for line in
      with requested as (
        select i.product_id, sum(i.units) as units
        from jsonb_to_recordset(p_items) as i(product_id text, units numeric) group by i.product_id
      ), old as (
        select product_id, sum(qty) as units from public.sale_items
        where sale_id = p_id and user_id = owner_id and product_id is not null group by product_id
      )
      select p.id, coalesce(old.units, 0) - coalesce(requested.units, 0) as qty_delta
      from public.products p
      left join requested on requested.product_id = p.id
      left join old on old.product_id = p.id
      where p.user_id = owner_id and (requested.product_id is not null or old.product_id is not null)
      order by p.id for update of p
    loop
      update public.products set qty = qty + line.qty_delta
      where id = line.id and user_id = owner_id and qty + line.qty_delta >= 0
      returning * into updated_product;
      if not found then raise exception 'رصيد المحل ما يكفي لإتمام البيع'; end if;
      affected := affected || jsonb_build_array(to_jsonb(updated_product));
    end loop;
    if exists (
      select 1 from jsonb_to_recordset(p_items) as i(product_id text, units numeric)
      where not exists (select 1 from public.products p where p.id = i.product_id and p.user_id = owner_id)
    ) then raise exception 'أحد الأصناف غير موجود بالمخزون'; end if;

    select greatest(sum(p.sell_price * i.units) - p_discount, 0) into invoice_total
    from jsonb_to_recordset(p_items) as i(product_id text, units numeric)
    join public.products p on p.id = i.product_id and p.user_id = owner_id;
    applied_paid := least(p_paid, invoice_total);
    if p_customer_id is null and applied_paid < invoice_total then
      raise exception 'اختَر عميل حتى تسجّل المبلغ المتبقي';
    end if;

    update public.sales set customer_id = p_customer_id, date = p_date,
      total = invoice_total, discount = p_discount, paid = applied_paid
    where id = p_id and user_id = owner_id returning * into invoice;
    delete from public.sale_items where sale_id = p_id and user_id = owner_id;
    insert into public.sale_items (id, user_id, sale_id, product_id, name, qty, sell_price, buy_price)
    select gen_random_uuid()::text, owner_id, p_id, p.id, p.name, sum(i.units), p.sell_price, p.buy_price
    from jsonb_to_recordset(p_items) as i(product_id text, units numeric)
    join public.products p on p.id = i.product_id and p.user_id = owner_id
    group by p.id;
    delete from public.payments where sale_id = p_id and user_id = owner_id;
    if applied_paid > 0 then
      insert into public.payments (id, user_id, customer_id, sale_id, amount, date, note)
      values (p_id || ':payment', owner_id, p_customer_id, p_id, applied_paid, p_date, 'دفعة عند البيع');
    end if;
  else
    select array_agg(product_id) into product_ids from public.sale_items
    where sale_id = p_id and user_id = owner_id;
    select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) into affected from public.products p
    where p.user_id = owner_id and p.id = any(product_ids);
  end if;

  return jsonb_build_object(
    'sale', to_jsonb(invoice),
    'items', (select coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) from public.sale_items i where i.sale_id = p_id and i.user_id = owner_id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from public.payments p where p.sale_id = p_id and p.user_id = owner_id),
    'products', affected
  );
end;
$$;

create function public.delete_inventory_sale(p_id text, p_product_ids text[])
returns setof public.products
language plpgsql security invoker set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  line record;
  affected_ids text[] := coalesce(p_product_ids, array[]::text[]);
begin
  perform 1 from public.sales where id = p_id and user_id = owner_id for update;
  if found then
    for line in
      select p.id, old.units from public.products p
      join (
        select product_id, sum(qty) as units from public.sale_items
        where sale_id = p_id and user_id = owner_id group by product_id
      ) old on old.product_id = p.id
      where p.user_id = owner_id order by p.id for update of p
    loop
      update public.products set qty = qty + line.units where id = line.id and user_id = owner_id;
      affected_ids := array_append(affected_ids, line.id);
    end loop;
    delete from public.sales where id = p_id and user_id = owner_id;
  end if;
  return query select p.* from public.products p where p.user_id = owner_id and p.id = any(affected_ids);
end;
$$;

revoke execute on function public.move_product_stock(text, text, text, text, numeric) from public, anon;
revoke execute on function public.save_inventory_sale(text, boolean, text, timestamptz, numeric, numeric, jsonb) from public, anon;
revoke execute on function public.delete_inventory_sale(text, text[]) from public, anon;
grant execute on function public.move_product_stock(text, text, text, text, numeric) to authenticated;
grant execute on function public.save_inventory_sale(text, boolean, text, timestamptz, numeric, numeric, jsonb) to authenticated;
grant execute on function public.delete_inventory_sale(text, text[]) to authenticated;
