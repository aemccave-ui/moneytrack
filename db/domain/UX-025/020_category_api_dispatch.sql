-- MoneyTrack — UX-025B — category CRUD transport dispatch
--
-- SOURCE ONLY until controlled UX-025 backend/n8n apply.
-- This wrapper preserves the accepted SPC-001 financial dispatcher for every
-- non-category route and extends only /api/v1/categories.

begin;

create or replace function moneytrack.ux025_financial_api_dispatch_v1(
    p_telegram_user_id bigint,
    p_space_id bigint,
    p_method text,
    p_path text,
    p_query jsonb default '{}'::jsonb,
    p_body jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
as $function$
declare
    v_actor bigint;
    v_method text := upper(coalesce(p_method, ''));
    v_path text := ltrim(coalesce(p_path, ''), '/');
    v_query jsonb := coalesce(p_query, '{}'::jsonb);
    v_body jsonb := coalesce(p_body, '{}'::jsonb);
    v_result jsonb;
    v_category_id bigint;
    v_parent_id bigint;
    v_sort_order integer;
begin
    if v_path <> 'api/v1/categories' then
        return moneytrack.spc001_financial_api_dispatch_v1(
            p_telegram_user_id,
            p_space_id,
            p_method,
            p_path,
            p_query,
            p_body
        );
    end if;

    v_actor := moneytrack.spc001_resolve_actor_user_id_v1(p_telegram_user_id);
    perform moneytrack.assert_space_member_v1(v_actor, p_space_id);

    if v_method = 'GET' then
        select jsonb_build_object('categories', c.categories)
          into v_result
          from moneytrack.category_directory_space_v1(v_actor, p_space_id) c;
        return coalesce(v_result, jsonb_build_object('categories', '[]'::jsonb));
    end if;

    if v_method = 'POST' then
        v_parent_id := nullif(v_body->>'parent_id', '')::bigint;
        v_sort_order := nullif(v_body->>'sort_order', '')::integer;
        select jsonb_build_object('category', c.category)
          into v_result
          from moneytrack.category_create_space_v1(
              v_actor,
              p_space_id,
              v_body->>'name',
              v_body->>'flow_type',
              v_parent_id,
              v_sort_order
          ) c;
        return v_result;
    end if;

    if v_method = 'PATCH' then
        v_category_id := nullif(v_body->>'category_id', '')::bigint;

        if lower(coalesce(v_body->>'action', '')) = 'reorder' then
            select to_jsonb(c)
              into v_result
              from moneytrack.category_reorder_space_v1(
                  v_actor,
                  p_space_id,
                  v_category_id,
                  v_body->>'direction'
              ) c;
            return v_result;
        end if;

        v_parent_id := nullif(v_body->>'parent_id', '')::bigint;
        v_sort_order := nullif(v_body->>'sort_order', '')::integer;
        select jsonb_build_object('category', c.category)
          into v_result
          from moneytrack.category_edit_space_v1(
              v_actor,
              p_space_id,
              v_category_id,
              v_body->>'name',
              v_body->>'flow_type',
              v_parent_id,
              v_sort_order
          ) c;
        return v_result;
    end if;

    if v_method = 'DELETE' then
        v_category_id := coalesce(
            nullif(v_query->>'id', '')::bigint,
            nullif(v_query->>'category_id', '')::bigint
        );
        select to_jsonb(c)
          into v_result
          from moneytrack.category_delete_space_v1(
              v_actor,
              p_space_id,
              v_category_id
          ) c;
        return v_result;
    end if;

    raise exception 'UX025_CATEGORY_METHOD_NOT_ALLOWED' using errcode = '42501';
end;
$function$;

comment on function moneytrack.ux025_financial_api_dispatch_v1(bigint,bigint,text,text,jsonb,jsonb)
is 'UX-025 financial API wrapper: category CRUD extension; all non-category routes delegate byte-semantically to the accepted SPC-001 dispatcher.';

commit;
