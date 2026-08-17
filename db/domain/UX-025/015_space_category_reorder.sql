-- MoneyTrack — UX-025B — atomic sibling category reorder
-- SOURCE ONLY until controlled UX-025 backend/runtime apply.

begin;

-- Replace the preliminary numeric setter with a deterministic sibling move.
drop function if exists moneytrack.category_reorder_space_v1(bigint,bigint,bigint,integer);

create or replace function moneytrack.category_reorder_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_category_id bigint,
    p_direction text
)
returns table(category_id bigint, sort_order integer, status text)
language plpgsql
volatile
as $function$
declare
    v_parent_id bigint;
    v_direction text := lower(nullif(btrim(p_direction), ''));
    v_ids bigint[];
    v_index integer;
    v_target integer;
    v_tmp bigint;
    v_i integer;
    v_count integer;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if v_direction is null or v_direction not in ('up', 'down') then
        raise exception 'CATEGORY_REORDER_DIRECTION_INVALID' using errcode = '22023';
    end if;

    select c.parent_id
      into v_parent_id
      from moneytrack.category_catalog c
     where c.id = p_category_id
       and c.space_id = p_space_id
       and coalesce(c.is_active, true) = true
     for update;

    if not found then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    -- One lock domain per sibling set. The transaction then rewrites the
    -- complete active sibling order to stable 10-point slots.
    perform pg_advisory_xact_lock(
        hashtextextended(
            'UX-025:category-order:' || p_space_id::text || ':' || coalesce(v_parent_id::text, 'root'),
            0
        )
    );

    select array_agg(c.id order by coalesce(c.sort_order, 0), c.id)
      into v_ids
      from moneytrack.category_catalog c
     where c.space_id = p_space_id
       and c.parent_id is not distinct from v_parent_id
       and coalesce(c.is_active, true) = true;

    v_index := array_position(v_ids, p_category_id);
    v_count := coalesce(cardinality(v_ids), 0);

    if v_index is null then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    v_target := case when v_direction = 'up' then v_index - 1 else v_index + 1 end;

    if v_target < 1 or v_target > v_count then
        select c.id, c.sort_order, 'boundary'::text
          into category_id, sort_order, status
          from moneytrack.category_catalog c
         where c.id = p_category_id;
        return next;
        return;
    end if;

    v_tmp := v_ids[v_index];
    v_ids[v_index] := v_ids[v_target];
    v_ids[v_target] := v_tmp;

    for v_i in 1..v_count loop
        update moneytrack.category_catalog c
           set sort_order = v_i * 10,
               updated_by_user_id = p_actor_user_id
         where c.id = v_ids[v_i]
           and c.space_id = p_space_id;
    end loop;

    select c.id, c.sort_order, 'reordered'::text
      into category_id, sort_order, status
      from moneytrack.category_catalog c
     where c.id = p_category_id;
    return next;
end;
$function$;

comment on function moneytrack.category_reorder_space_v1(bigint,bigint,bigint,text)
is 'UX-025 atomic sibling reorder. Direction is up/down; all active siblings are normalized to deterministic 10-point sort slots.';

commit;
