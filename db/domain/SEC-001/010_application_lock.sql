-- MoneyTrack — SEC-001 — application lock security domain
--
-- Stores only verifier/hash material. Plain PINs, raw biometric tokens,
-- raw MoneyTrack unlock tokens and the server-side PIN pepper never enter DB.

begin;

create table if not exists moneytrack.user_security (
    user_id bigint primary key references moneytrack.app_users(id) on delete cascade,
    pin_salt text,
    pin_verifier text,
    pin_enabled boolean not null default false,
    failed_attempts integer not null default 0 check (failed_attempts >= 0),
    locked_until timestamptz,
    security_version bigint not null default 1 check (security_version > 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (
        (pin_enabled = false)
        or (
            pin_salt ~ '^[0-9a-f]{32}$'
            and pin_verifier ~ '^[0-9a-f]{64}$'
        )
    )
);

create table if not exists moneytrack.user_unlock_sessions (
    id bigserial primary key,
    user_id bigint not null references moneytrack.app_users(id) on delete cascade,
    token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
    security_version bigint not null check (security_version > 0),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    last_used_at timestamptz,
    revoked_at timestamptz,
    check (expires_at > created_at)
);

create index if not exists user_unlock_sessions_active_idx
    on moneytrack.user_unlock_sessions(user_id, expires_at)
    where revoked_at is null;

create table if not exists moneytrack.user_biometric_credentials (
    id bigserial primary key,
    user_id bigint not null references moneytrack.app_users(id) on delete cascade,
    device_id text not null,
    token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz not null default now(),
    last_used_at timestamptz,
    revoked_at timestamptz,
    unique (user_id, device_id),
    check (length(device_id) between 1 and 512)
);

create index if not exists user_biometric_credentials_active_idx
    on moneytrack.user_biometric_credentials(user_id, device_id)
    where revoked_at is null;


create or replace function moneytrack.security_status_v1(
    p_telegram_user_id bigint,
    p_device_id text default null
)
returns table (
    user_id bigint,
    pin_enabled boolean,
    failed_attempts integer,
    locked_until timestamptz,
    security_version bigint,
    biometric_enrolled boolean
)
language sql
stable
as $function$
    select
        u.id,
        coalesce(s.pin_enabled, false),
        coalesce(s.failed_attempts, 0),
        s.locked_until,
        coalesce(s.security_version, 1),
        exists (
            select 1
            from moneytrack.user_biometric_credentials b
            where b.user_id = u.id
              and b.device_id = nullif(btrim(p_device_id), '')
              and b.revoked_at is null
        )
    from moneytrack.app_users u
    left join moneytrack.user_security s on s.user_id = u.id
    where u.telegram_user_id = p_telegram_user_id
    limit 1;
$function$;

comment on function moneytrack.security_status_v1(bigint,text)
is 'SEC-001 minimal pre-unlock status. Exposes only application-lock state, never financial/private data.';


create or replace function moneytrack.security_setup_pin_v1(
    p_user_id bigint,
    p_pin_salt text,
    p_pin_verifier text
)
returns table (
    user_id bigint,
    pin_enabled boolean,
    security_version bigint
)
language plpgsql
volatile
as $function$
declare
    v_version bigint;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if p_pin_salt is null or p_pin_salt !~ '^[0-9a-f]{32}$' then
        raise exception 'PIN_SALT_INVALID' using errcode = '22023';
    end if;

    if p_pin_verifier is null or p_pin_verifier !~ '^[0-9a-f]{64}$' then
        raise exception 'PIN_VERIFIER_INVALID' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('SEC-001:user-security:' || p_user_id::text, 0)
    );

    if exists (
        select 1
        from moneytrack.user_security s
        where s.user_id = p_user_id
          and s.pin_enabled = true
    ) then
        raise exception 'PIN_ALREADY_ENABLED' using errcode = 'P0001';
    end if;

    insert into moneytrack.user_security (
        user_id,
        pin_salt,
        pin_verifier,
        pin_enabled,
        failed_attempts,
        locked_until,
        security_version,
        created_at,
        updated_at
    ) values (
        p_user_id,
        p_pin_salt,
        p_pin_verifier,
        true,
        0,
        null,
        1,
        now(),
        now()
    )
    on conflict on constraint user_security_pkey do update
    set
        pin_salt = excluded.pin_salt,
        pin_verifier = excluded.pin_verifier,
        pin_enabled = true,
        failed_attempts = 0,
        locked_until = null,
        security_version = moneytrack.user_security.security_version + 1,
        updated_at = now()
    returning moneytrack.user_security.security_version into v_version;

    update moneytrack.user_unlock_sessions
       set revoked_at = coalesce(revoked_at, now())
     where user_unlock_sessions.user_id = p_user_id
       and revoked_at is null;

    return query select p_user_id, true, v_version;
end;
$function$;


create or replace function moneytrack.security_pin_state_v1(
    p_telegram_user_id bigint
)
returns table (
    user_id bigint,
    pin_enabled boolean,
    pin_salt text,
    pin_verifier text,
    failed_attempts integer,
    locked_until timestamptz,
    security_version bigint
)
language sql
stable
as $function$
    select
        u.id,
        coalesce(s.pin_enabled, false),
        s.pin_salt,
        s.pin_verifier,
        coalesce(s.failed_attempts, 0),
        s.locked_until,
        coalesce(s.security_version, 1)
    from moneytrack.app_users u
    left join moneytrack.user_security s on s.user_id = u.id
    where u.telegram_user_id = p_telegram_user_id
    limit 1;
$function$;


create or replace function moneytrack.security_record_pin_failure_v1(
    p_user_id bigint
)
returns table (
    failed_attempts integer,
    locked_until timestamptz,
    error_code text
)
language plpgsql
volatile
as $function$
declare
    v_attempts integer;
    v_locked_until timestamptz;
begin
    perform pg_advisory_xact_lock(
        hashtextextended('SEC-001:user-security:' || p_user_id::text, 0)
    );

    select s.failed_attempts, s.locked_until
      into v_attempts, v_locked_until
      from moneytrack.user_security s
     where s.user_id = p_user_id
       and s.pin_enabled = true
     for update;

    if not found then
        raise exception 'PIN_NOT_ENABLED' using errcode = 'P0001';
    end if;

    if v_locked_until is not null and v_locked_until > now() then
        return query select v_attempts, v_locked_until, 'PIN_LOCKED'::text;
        return;
    end if;

    v_attempts := coalesce(v_attempts, 0) + 1;
    v_locked_until := case
        when v_attempts >= 5 then now() + interval '5 minutes'
        else null
    end;

    update moneytrack.user_security s
       set failed_attempts = v_attempts,
           locked_until = v_locked_until,
           updated_at = now()
     where s.user_id = p_user_id;

    return query
    select
        v_attempts,
        v_locked_until,
        case when v_locked_until is null then 'PIN_INVALID' else 'PIN_LOCKED' end::text;
end;
$function$;


create or replace function moneytrack.security_record_pin_success_v1(
    p_user_id bigint
)
returns void
language sql
volatile
as $function$
    update moneytrack.user_security
       set failed_attempts = 0,
           locked_until = null,
           updated_at = now()
     where user_id = p_user_id
       and pin_enabled = true;
$function$;


create or replace function moneytrack.security_issue_session_v1(
    p_user_id bigint,
    p_token_hash text,
    p_ttl_seconds integer default 900
)
returns table (
    expires_at timestamptz,
    security_version bigint
)
language plpgsql
volatile
as $function$
declare
    v_version bigint;
    v_expires timestamptz;
begin
    if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'UNLOCK_TOKEN_HASH_INVALID' using errcode = '22023';
    end if;

    if p_ttl_seconds < 60 or p_ttl_seconds > 3600 then
        raise exception 'UNLOCK_TTL_INVALID' using errcode = '22023';
    end if;

    select s.security_version
      into v_version
      from moneytrack.user_security s
     where s.user_id = p_user_id
       and s.pin_enabled = true;

    if v_version is null then
        raise exception 'PIN_NOT_ENABLED' using errcode = 'P0001';
    end if;

    v_expires := now() + make_interval(secs => p_ttl_seconds);

    insert into moneytrack.user_unlock_sessions (
        user_id,
        token_hash,
        security_version,
        expires_at
    ) values (
        p_user_id,
        p_token_hash,
        v_version,
        v_expires
    );

    return query select v_expires, v_version;
end;
$function$;


create or replace function moneytrack.security_validate_unlock_v1(
    p_telegram_user_id bigint,
    p_token_hash text
)
returns table (
    unlock_ok boolean,
    protection_enabled boolean,
    user_id bigint,
    error_code text,
    expires_at timestamptz
)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_enabled boolean;
    v_version bigint;
    v_session_id bigint;
    v_expires timestamptz;
begin
    select
        u.id,
        coalesce(s.pin_enabled, false),
        coalesce(s.security_version, 1)
      into
        v_user_id,
        v_enabled,
        v_version
      from moneytrack.app_users u
      left join moneytrack.user_security s on s.user_id = u.id
     where u.telegram_user_id = p_telegram_user_id
     limit 1;

    if v_user_id is null then
        return query select false, false, null::bigint, 'USER_NOT_FOUND'::text, null::timestamptz;
        return;
    end if;

    if not v_enabled then
        return query select true, false, v_user_id, null::text, null::timestamptz;
        return;
    end if;

    if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
        return query select false, true, v_user_id, 'UNLOCK_REQUIRED'::text, null::timestamptz;
        return;
    end if;

    select s.id, s.expires_at
      into v_session_id, v_expires
      from moneytrack.user_unlock_sessions s
     where s.user_id = v_user_id
       and s.token_hash = p_token_hash
       and s.security_version = v_version
       and s.revoked_at is null
       and s.expires_at > now()
     limit 1;

    if v_session_id is null then
        return query select false, true, v_user_id, 'UNLOCK_INVALID'::text, null::timestamptz;
        return;
    end if;

    update moneytrack.user_unlock_sessions
       set last_used_at = now()
     where id = v_session_id;

    return query select true, true, v_user_id, null::text, v_expires;
end;
$function$;


create or replace function moneytrack.security_enroll_biometric_v1(
    p_user_id bigint,
    p_device_id text,
    p_token_hash text
)
returns table (
    credential_id bigint,
    device_id text
)
language plpgsql
volatile
as $function$
declare
    v_id bigint;
    v_device text := nullif(btrim(p_device_id), '');
begin
    if v_device is null or length(v_device) > 512 then
        raise exception 'BIOMETRIC_DEVICE_ID_INVALID' using errcode = '22023';
    end if;

    if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'BIOMETRIC_TOKEN_HASH_INVALID' using errcode = '22023';
    end if;

    if not exists (
        select 1
        from moneytrack.user_security s
        where s.user_id = p_user_id
          and s.pin_enabled = true
    ) then
        raise exception 'PIN_NOT_ENABLED' using errcode = 'P0001';
    end if;

    insert into moneytrack.user_biometric_credentials (
        user_id,
        device_id,
        token_hash,
        created_at,
        revoked_at
    ) values (
        p_user_id,
        v_device,
        p_token_hash,
        now(),
        null
    )
    on conflict on constraint user_biometric_credentials_user_id_device_id_key do update
    set token_hash = excluded.token_hash,
        created_at = now(),
        last_used_at = null,
        revoked_at = null
    returning id into v_id;

    return query select v_id, v_device;
end;
$function$;


create or replace function moneytrack.security_validate_biometric_v1(
    p_telegram_user_id bigint,
    p_device_id text,
    p_token_hash text
)
returns table (
    biometric_ok boolean,
    user_id bigint,
    error_code text
)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_id bigint;
begin
    select u.id
      into v_user_id
      from moneytrack.app_users u
      join moneytrack.user_security s
        on s.user_id = u.id
       and s.pin_enabled = true
     where u.telegram_user_id = p_telegram_user_id
     limit 1;

    if v_user_id is null then
        return query select false, null::bigint, 'PIN_NOT_ENABLED'::text;
        return;
    end if;

    select b.id
      into v_id
      from moneytrack.user_biometric_credentials b
     where b.user_id = v_user_id
       and b.device_id = nullif(btrim(p_device_id), '')
       and b.token_hash = p_token_hash
       and b.revoked_at is null
     limit 1;

    if v_id is null then
        return query select false, v_user_id, 'BIOMETRIC_INVALID'::text;
        return;
    end if;

    update moneytrack.user_biometric_credentials
       set last_used_at = now()
     where id = v_id;

    return query select true, v_user_id, null::text;
end;
$function$;


create or replace function moneytrack.security_revoke_biometric_v1(
    p_user_id bigint,
    p_device_id text
)
returns boolean
language plpgsql
volatile
as $function$
begin
    update moneytrack.user_biometric_credentials
       set revoked_at = coalesce(revoked_at, now())
     where user_id = p_user_id
       and device_id = nullif(btrim(p_device_id), '')
       and revoked_at is null;

    return found;
end;
$function$;


create or replace function moneytrack.security_change_pin_v1(
    p_user_id bigint,
    p_expected_security_version bigint,
    p_pin_salt text,
    p_pin_verifier text,
    p_new_token_hash text,
    p_ttl_seconds integer default 900
)
returns table (
    security_version bigint,
    expires_at timestamptz
)
language plpgsql
volatile
as $function$
declare
    v_version bigint;
    v_expires timestamptz;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;
    if p_expected_security_version is null or p_expected_security_version <= 0 then
        raise exception 'SECURITY_VERSION_REQUIRED' using errcode = '22023';
    end if;
    if p_pin_salt is null or p_pin_salt !~ '^[0-9a-f]{32}$' then
        raise exception 'PIN_SALT_INVALID' using errcode = '22023';
    end if;
    if p_pin_verifier is null or p_pin_verifier !~ '^[0-9a-f]{64}$' then
        raise exception 'PIN_VERIFIER_INVALID' using errcode = '22023';
    end if;
    if p_new_token_hash is null or p_new_token_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'UNLOCK_TOKEN_HASH_INVALID' using errcode = '22023';
    end if;
    if p_ttl_seconds < 60 or p_ttl_seconds > 3600 then
        raise exception 'UNLOCK_TTL_INVALID' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('SEC-001:user-security:' || p_user_id::text, 0)
    );

    update moneytrack.user_security s
       set pin_salt = p_pin_salt,
           pin_verifier = p_pin_verifier,
           failed_attempts = 0,
           locked_until = null,
           security_version = s.security_version + 1,
           updated_at = now()
     where s.user_id = p_user_id
       and s.pin_enabled = true
       and s.security_version = p_expected_security_version
    returning s.security_version into v_version;

    if v_version is null then
        raise exception 'SECURITY_VERSION_CHANGED' using errcode = 'P0001';
    end if;

    -- Rotation invalidates every pre-change MoneyTrack unlock session, including
    -- the session used for this Class B request. A replacement is issued below.
    update moneytrack.user_unlock_sessions us
       set revoked_at = coalesce(us.revoked_at, now())
     where us.user_id = p_user_id
       and us.revoked_at is null;

    v_expires := now() + make_interval(secs => p_ttl_seconds);
    insert into moneytrack.user_unlock_sessions (
        user_id, token_hash, security_version, expires_at
    ) values (
        p_user_id, p_new_token_hash, v_version, v_expires
    );

    return query select v_version, v_expires;
end;
$function$;

comment on function moneytrack.security_change_pin_v1(bigint,bigint,text,text,text,integer)
is 'SEC-001 atomic PIN rotation boundary. Rotates verifier/version, revokes all prior unlock sessions, resets PIN failures, and issues exactly one replacement hashed session.';


create or replace function moneytrack.security_disable_v1(
    p_user_id bigint,
    p_expected_security_version bigint
)
returns table (
    security_version bigint,
    sessions_revoked integer,
    biometrics_revoked integer
)
language plpgsql
volatile
as $function$
declare
    v_version bigint;
    v_sessions integer := 0;
    v_biometrics integer := 0;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;
    if p_expected_security_version is null or p_expected_security_version <= 0 then
        raise exception 'SECURITY_VERSION_REQUIRED' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('SEC-001:user-security:' || p_user_id::text, 0)
    );

    update moneytrack.user_security s
       set pin_enabled = false,
           pin_salt = null,
           pin_verifier = null,
           failed_attempts = 0,
           locked_until = null,
           security_version = s.security_version + 1,
           updated_at = now()
     where s.user_id = p_user_id
       and s.pin_enabled = true
       and s.security_version = p_expected_security_version
    returning s.security_version into v_version;

    if v_version is null then
        raise exception 'SECURITY_VERSION_CHANGED' using errcode = 'P0001';
    end if;

    update moneytrack.user_unlock_sessions us
       set revoked_at = coalesce(us.revoked_at, now())
     where us.user_id = p_user_id
       and us.revoked_at is null;
    get diagnostics v_sessions = row_count;

    -- Server-side revocation is authoritative and deliberately covers every
    -- enrolled device, not only the device sending the disable request.
    update moneytrack.user_biometric_credentials b
       set revoked_at = coalesce(b.revoked_at, now())
     where b.user_id = p_user_id
       and b.revoked_at is null;
    get diagnostics v_biometrics = row_count;

    return query select v_version, v_sessions, v_biometrics;
end;
$function$;

comment on function moneytrack.security_disable_v1(bigint,bigint)
is 'SEC-001 atomic application-lock disable boundary. Clears PIN verifier state, rotates security version, and revokes all unlock sessions and all biometric credentials for the user.';

commit;
