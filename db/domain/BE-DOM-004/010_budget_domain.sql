-- MoneyTrack — BE-DOM-004 — budget domain boundaries
--
-- Active n8n workflows may parse/format budget commands, but persistence,
-- tenant ownership and budget mutation semantics belong to PostgreSQL.

begin;

create or replace function moneytrack.budget_create_rule_v1(
    p_user_id bigint,
    p_input_status text,
    p_category_id bigint,
    p_name text,
    p_amount numeric,
    p_currency_code text,
    p_recurrence_type text,
    p_recurrence_interval integer,
    p_valid_from date,
    p_valid_to date
)
returns table (
    id bigint,
    category_id bigint,
    name text,
    amount numeric,
    currency_code text,
    recurrence_type text,
    recurrence_interval integer,
    valid_from date,
    valid_to date,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_status text := nullif(btrim(p_input_status), '');
    v_id bigint;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    -- Preserve the existing adapter contract: unresolved parser/category states
    -- are returned without creating a rule.
    if v_status is distinct from 'resolved' then
        return query
        select
            null::bigint,
            p_category_id,
            p_name,
            p_amount,
            p_currency_code,
            p_recurrence_type,
            p_recurrence_interval,
            p_valid_from,
            p_valid_to,
            coalesce(v_status, 'invalid_command')::text;
        return;
    end if;

    -- category_id is a tenant-owned domain reference. The database FK alone
    -- proves existence, not ownership, so enforce the user/category boundary here.
    if p_category_id is null or not exists (
        select 1
        from moneytrack.category_catalog c
        where c.id = p_category_id
          and c.user_id = p_user_id
          and coalesce(c.is_active, true) = true
    ) then
        return query
        select
            null::bigint,
            p_category_id,
            p_name,
            p_amount,
            p_currency_code,
            p_recurrence_type,
            p_recurrence_interval,
            p_valid_from,
            p_valid_to,
            'not_found'::text;
        return;
    end if;

    -- Keep required-field failures fail-closed at the backend boundary instead
    -- of relying on a later NOT NULL error from budget_rules.
    if p_amount is null
       or nullif(btrim(p_currency_code), '') is null
       or nullif(btrim(p_recurrence_type), '') is null
       or p_recurrence_interval is null
       or p_valid_from is null then
        return query
        select
            null::bigint,
            p_category_id,
            p_name,
            p_amount,
            p_currency_code,
            p_recurrence_type,
            p_recurrence_interval,
            p_valid_from,
            p_valid_to,
            'invalid_command'::text;
        return;
    end if;

    insert into moneytrack.budget_rules (
        user_id,
        category_id,
        name,
        amount,
        currency_code,
        recurrence_type,
        recurrence_interval,
        valid_from,
        valid_to,
        is_active
    ) values (
        p_user_id,
        p_category_id,
        p_name,
        p_amount,
        p_currency_code,
        p_recurrence_type,
        p_recurrence_interval,
        p_valid_from,
        p_valid_to,
        true
    )
    returning budget_rules.id into v_id;

    return query
    select
        br.id,
        br.category_id,
        br.name,
        br.amount,
        br.currency_code,
        br.recurrence_type,
        br.recurrence_interval,
        br.valid_from,
        br.valid_to,
        'added'::text
    from moneytrack.budget_rules br
    where br.id = v_id
      and br.user_id = p_user_id;
end;
$function$;

comment on function moneytrack.budget_create_rule_v1(bigint,text,bigint,text,numeric,text,text,integer,date,date)
is 'BE-DOM-004 canonical budget-rule creation boundary. Preserves unresolved adapter status, validates tenant-owned category references and persists a resolved rule for the authenticated user.';


create or replace function moneytrack.budget_apply_action_v1(
    p_user_id bigint,
    p_action text,
    p_budget_rule_id bigint
)
returns table (
    id bigint,
    name text,
    amount numeric,
    currency_code text,
    recurrence_type text,
    recurrence_interval integer,
    valid_from date,
    valid_to date,
    is_active boolean,
    action text,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_action text := nullif(btrim(p_action), '');
    v_id bigint;
    v_name text;
    v_amount numeric;
    v_currency_code text;
    v_recurrence_type text;
    v_recurrence_interval integer;
    v_valid_from date;
    v_valid_to date;
    v_is_active boolean;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if v_action is null or p_budget_rule_id is null then
        return query
        select
            null::bigint, null::text, null::numeric, null::text, null::text,
            null::integer, null::date, null::date, null::boolean,
            v_action, 'invalid_command'::text;
        return;
    end if;

    -- Lock only a rule owned by the authenticated user. A foreign rule is
    -- deliberately indistinguishable from a missing rule to the adapter.
    select
        br.id,
        br.name,
        br.amount,
        br.currency_code,
        br.recurrence_type,
        br.recurrence_interval,
        br.valid_from,
        br.valid_to,
        br.is_active
      into
        v_id,
        v_name,
        v_amount,
        v_currency_code,
        v_recurrence_type,
        v_recurrence_interval,
        v_valid_from,
        v_valid_to,
        v_is_active
      from moneytrack.budget_rules br
     where br.id = p_budget_rule_id
       and br.user_id = p_user_id
     for update;

    if v_id is null or v_action not in ('enable', 'disable', 'delete') then
        return query
        select
            null::bigint, null::text, null::numeric, null::text, null::text,
            null::integer, null::date, null::date, null::boolean,
            v_action, 'not_found'::text;
        return;
    end if;

    if v_action = 'delete' then
        delete from moneytrack.budget_rules br
         where br.id = v_id
           and br.user_id = p_user_id;

        return query
        select
            v_id,
            v_name,
            v_amount,
            v_currency_code,
            v_recurrence_type,
            v_recurrence_interval,
            v_valid_from,
            v_valid_to,
            false,
            v_action,
            v_action;
        return;
    end if;

    update moneytrack.budget_rules br
       set is_active = (v_action = 'enable')
     where br.id = v_id
       and br.user_id = p_user_id
    returning br.is_active into v_is_active;

    return query
    select
        v_id,
        v_name,
        v_amount,
        v_currency_code,
        v_recurrence_type,
        v_recurrence_interval,
        v_valid_from,
        v_valid_to,
        v_is_active,
        v_action,
        v_action;
end;
$function$;

comment on function moneytrack.budget_apply_action_v1(bigint,text,bigint)
is 'BE-DOM-004 canonical budget mutation boundary. Applies enable/disable/delete only to a rule owned by the authenticated user, with missing/foreign rules returning not_found.';

commit;
