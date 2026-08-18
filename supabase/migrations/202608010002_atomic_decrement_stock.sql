-- Trừ kho atomic: chỉ trừ khi còn đủ hàng (WHERE quantity >= p_qty),
-- tránh âm kho khi hai thao tác cùng trừ một linh kiện đồng thời.
create or replace function public.decrement_stock(p_part_id uuid, p_qty int)
returns int
language sql
security invoker
as $$
  update public.inventory_parts
     set quantity = quantity - p_qty
   where id = p_part_id and quantity >= p_qty
  returning quantity;
$$;
