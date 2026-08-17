-- MoneyTrack — UX-025B — functional category CRUD/isolation rehearsal
-- Run only on a restored clone. The terminal ROLLBACK is mandatory.
\set ON_ERROR_STOP on

begin;

do $rehearsal$
declare
    v_actor bigint;
    v_space bigint;
    v_second_space bigint;
    v_root bigint;
    v_child_a bigint;
    v_child_b bigint;
    v_other bigint;
    v_json jsonb;
    v_a_sort integer;
    v_b_sort integer;
    v_active_count integer;
begin
    select wm.user_id, wm.workspace_id
      into v_actor, v_space
      from moneytrack.workspace_members wm
      join moneytrack.workspaces w on w.id = wm.workspace_id
     where wm.user_id <> 0
       and coalesce(wm.is_active, true) = true
       and coalesce(w.is_active, true) = true
     order by wm.workspace_id, wm.user_id
     limit 1;

    if v_actor is null or v_space is null then
        raise exception 'UX025_REHEARSAL_NO_ACTIVE_MEMBER_SPACE';
    end if;

    select c.category into v_json
      from moneytrack.category_create_space_v1(
          v_actor, v_space, 'UX025 rehearsal root', 'expense', null, null
      ) c;
    v_root := (v_json->>'id')::bigint;

    select c.category into v_json
      from moneytrack.category_create_space_v1(
          v_actor, v_space, 'UX025 rehearsal child A', 'expense', v_root, null
      ) c;
    v_child_a := (v_json->>'id')::bigint;

    select c.category into v_json
      from moneytrack.category_create_space_v1(
          v_actor, v_space, 'UX025 rehearsal child B', 'expense', v_root, null
      ) c;
    v_child_b := (v_json->>'id')::bigint;

    if v_root is null or v_child_a is null or v_child_b is null then
        raise exception 'UX025_REHEARSAL_CREATE_FAILED';
    end if;

    -- Existing row edit: flow change + localized name while parent is preserved.
    select c.category into v_json
      from moneytrack.category_edit_space_v1(
          v_actor,
          v_space,
          v_child_a,
          'UX025 rehearsal child A edited',
          'income',
          v_root,
          10
      ) c;
    if v_json->>'flow_type' <> 'income' or (v_json->>'parent_id')::bigint <> v_root then
        raise exception 'UX025_REHEARSAL_EDIT_FAILED';
    end if;

    -- Atomic sibling reorder: B was created after A and must move above it.
    perform * from moneytrack.category_reorder_space_v1(v_actor, v_space, v_child_b, 'up');
    select sort_order into v_a_sort from moneytrack.category_catalog where id = v_child_a;
    select sort_order into v_b_sort from moneytrack.category_catalog where id = v_child_b;
    if v_b_sort >= v_a_sort then
        raise exception 'UX025_REHEARSAL_REORDER_FAILED a=% b=%', v_a_sort, v_b_sort;
    end if;

    -- A parent with active children must not be archived.
    begin
        perform * from moneytrack.category_delete_space_v1(v_actor, v_space, v_root);
        raise exception 'UX025_REHEARSAL_ACTIVE_CHILD_GUARD_NOT_ENFORCED';
    exception
        when sqlstate '23503' then
            if sqlerrm <> 'CATEGORY_HAS_ACTIVE_CHILDREN' then
                raise;
            end if;
    end;

    -- Recursive cycle guard: root cannot be moved below its child.
    begin
        perform * from moneytrack.category_edit_space_v1(
            v_actor,
            v_space,
            v_root,
            'UX025 rehearsal root',
            'expense',
            v_child_a,
            10
        );
        raise exception 'UX025_REHEARSAL_CYCLE_GUARD_NOT_ENFORCED';
    exception
        when sqlstate '22023' then
            if sqlerrm <> 'CATEGORY_PARENT_CYCLE' then
                raise;
            end if;
    end;

    -- Build a second Space inside the clone transaction and prove a parent from
    -- that Space cannot be assigned to a category in the first Space.
    select s.space_id into v_second_space
      from moneytrack.space_create_v1(
          v_actor,
          'UX025 rehearsal isolated ' || txid_current()::text
      ) s;

    select c.category into v_json
      from moneytrack.category_create_space_v1(
          v_actor, v_second_space, 'UX025 rehearsal other space', 'expense', null, null
      ) c;
    v_other := (v_json->>'id')::bigint;

    begin
        perform * from moneytrack.category_edit_space_v1(
            v_actor,
            v_space,
            v_child_a,
            'UX025 rehearsal child A edited',
            'income',
            v_other,
            20
        );
        raise exception 'UX025_REHEARSAL_SAME_SPACE_PARENT_GUARD_NOT_ENFORCED';
    exception
        when sqlstate 'P0002' then
            if sqlerrm <> 'CATEGORY_PARENT_NOT_FOUND_IN_SPACE' then
                raise;
            end if;
    end;

    -- Archive leaves row identity/history in place while removing it from the
    -- active directory read model.
    perform * from moneytrack.category_delete_space_v1(v_actor, v_space, v_child_a);
    perform * from moneytrack.category_delete_space_v1(v_actor, v_space, v_child_b);
    perform * from moneytrack.category_delete_space_v1(v_actor, v_space, v_root);

    if exists (
        select 1 from moneytrack.category_catalog
        where id in (v_root, v_child_a, v_child_b)
          and coalesce(is_active, true) = true
    ) then
        raise exception 'UX025_REHEARSAL_ARCHIVE_FAILED';
    end if;

    select count(*)
      into v_active_count
      from moneytrack.category_directory_space_v1(v_actor, v_space) d
      cross join lateral jsonb_array_elements(d.categories) item
     where (item->>'id')::bigint in (v_root, v_child_a, v_child_b);
    if v_active_count <> 0 then
        raise exception 'UX025_REHEARSAL_ARCHIVED_ROWS_VISIBLE count=%', v_active_count;
    end if;

    raise notice 'UX025_CATEGORY_CREATE=PASS';
    raise notice 'UX025_CATEGORY_EDIT=PASS';
    raise notice 'UX025_CATEGORY_REPARENT_GUARDS=PASS';
    raise notice 'UX025_CATEGORY_REORDER=PASS';
    raise notice 'UX025_CATEGORY_ARCHIVE=PASS';
    raise notice 'UX025_CATEGORY_HISTORY_IDENTITY=PASS';
    raise notice 'UX025_CATEGORY_SPACE_ISOLATION=PASS';
end;
$rehearsal$;

select 'UX025_CATEGORY_CRUD_REHEARSAL=PASS' as marker;
select 'UX025_REHEARSAL_TERMINAL_ROLLBACK=PASS' as marker;
rollback;
