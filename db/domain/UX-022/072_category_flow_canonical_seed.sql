-- MoneyTrack — UX-022R3 — Canonical category flow seed
-- Apply after 070_category_flow_settings.sql and 071_category_flow_bootstrap_hardening.sql.
--
-- Deep runtime forensic proved that the active standard catalog is a repeated copy
-- of template user 0. We seed only semantically deterministic codes. `transfer`
-- is not an operation category (transfers have their own domain entity) and
-- `uncategorized` is represented canonically by transactions.category_id IS NULL;
-- both legacy/system catalog rows are therefore deactivated instead of being
-- assigned a fake income/expense flow.

begin;

-- Canonical template: income root is income; ordinary spending/reporting roots
-- and their current descendants are expense.
update moneytrack.category_catalog c
   set flow_type = 'income'
 where c.user_id = 0
   and c.code = 'income';

update moneytrack.category_catalog c
   set flow_type = 'expense'
 where c.user_id = 0
   and c.code in (
       'food',
       'food.groceries',
       'food.vegetables',
       'food.fruits',
       'food.bakery',
       'food.dairy',
       'food.meat',
       'food.fish',
       'food.drinks',
       'transport',
       'home',
       'health',
       'entertainment',
       'finance',
       'finance.fees'
   );

-- The two legacy/system codes are deliberately not part of the editable/selectable
-- financial category directory.
update moneytrack.category_catalog c
   set is_active = false,
       flow_type = null
 where c.code in ('transfer', 'uncategorized')
   and coalesce(c.is_active, true) = true;

-- Propagate canonical template semantics to every existing user-owned copy.
update moneytrack.category_catalog c
   set flow_type = template.flow_type
  from moneytrack.category_catalog template
 where template.user_id = 0
   and template.code = c.code
   and template.flow_type in ('income', 'expense')
   and c.user_id <> 0
   and coalesce(c.is_active, true) = true;

-- Legacy user catalog proven by deep forensic. The code hierarchy itself carries
-- deterministic financial semantics; no posting-history guess is needed.
update moneytrack.category_catalog c
   set flow_type = 'income'
 where c.user_id <> 0
   and coalesce(c.is_active, true) = true
   and (c.code = 'income' or c.code like 'income.%');

update moneytrack.category_catalog c
   set flow_type = 'expense'
 where c.user_id <> 0
   and coalesce(c.is_active, true) = true
   and (
       c.code in ('legal', 'life', 'other', 'required')
       or c.code like 'legal.%'
       or c.code like 'life.%'
       or c.code like 'other.%'
       or c.code like 'required.%'
   );

-- 070 already infers one-sided historical usage (including QA-only categories).
-- After the canonical seed every active user-facing category must be classified.
do $category_flow_postcondition$
begin
    if exists (
        select 1
          from moneytrack.category_catalog c
         where coalesce(c.is_active, true) = true
           and c.user_id <> 0
           and c.code not in ('transfer', 'uncategorized')
           and c.flow_type is null
    ) then
        raise exception 'UX022R3_CATEGORY_FLOW_UNRESOLVED_AFTER_CANONICAL_SEED';
    end if;

    if exists (
        select 1
          from moneytrack.category_catalog c
         where coalesce(c.is_active, true) = true
           and c.user_id = 0
           and c.code not in ('transfer', 'uncategorized')
           and c.flow_type is null
    ) then
        raise exception 'UX022R3_TEMPLATE_FLOW_UNRESOLVED_AFTER_CANONICAL_SEED';
    end if;
end;
$category_flow_postcondition$;

commit;
