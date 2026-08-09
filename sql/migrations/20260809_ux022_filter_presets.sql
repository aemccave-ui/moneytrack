begin;

create table if not exists moneytrack.filter_presets (
    id bigserial primary key,
    user_id bigint not null references moneytrack.app_users(id) on delete cascade,
    name text not null,
    account_ids bigint[] not null default '{}'::bigint[],
    income_category_ids bigint[] not null default '{}'::bigint[],
    expense_category_ids bigint[] not null default '{}'::bigint[],
    created_at timestamptz not null default now(),
    constraint filter_presets_name_not_blank check (length(btrim(name)) between 1 and 80)
);

create index if not exists filter_presets_user_created_idx
    on moneytrack.filter_presets (user_id, created_at, id);

commit;
