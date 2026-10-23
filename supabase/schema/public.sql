


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."add_promo_printings"("p_set" bigint, "p_apply" boolean DEFAULT false) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $_$
declare k record; n int := 0; v_lang text; v_game text; base text; vlabel text; tag text;
begin
  select language, game_id into v_lang, v_game from sets where id = p_set;
  for k in select t.* from tcgp_keys t where t.set_id = p_set and t.sub_type in ('Normal', 'Holofoil', 'Reverse Holofoil') order by t.num, t.product_id loop
    tag := tcgp_promo_tag(k.name);
    vlabel := case when tag like '%cosmos holo%' then 'Holofoil (Cosmos)' when tag like '%cracked ice%' then 'Holofoil (Cracked Ice)' else k.sub_type end;
    -- already held: same number, same finish family and the same tags in our name
    continue when exists (select 1 from products p where p.set_id = p_set and p.kind = 'card' and tcgp_num(p.card_number) = k.num
                           and tcgp_our_tag(p.name, p.variant) = tcgp_their_tag(k.name)
                           and ((select count(*) from tcgp_keys t2 where t2.set_id = p_set and t2.num = k.num and tcgp_their_tag(t2.name) = tcgp_their_tag(k.name)) = 1
                                or (select sub_type from tcgp_variant_key(p.variant)) = k.sub_type));
    n := n + 1;
    base := trim(regexp_replace(regexp_replace(k.name, '\s+-\s+[A-Za-z0-9/]+(\s|$).*$', ''), '\s*\(.*$', ''));
    if p_apply then
      insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, image_url, external_ids, price_tier, special)
      values (v_game, p_set, 'card',
              base || coalesce(' (' || nullif(initcap(replace(replace(replace(tag, '|', ') ('), 'cosmos holo', ''), 'cracked ice holo', '')), '') || ')', ''),
              k.number, k.rarity, vlabel, v_lang, replace(k.image_url, '_200w.jpg', '_in_1000x1000.jpg'),
              jsonb_build_object('tcgplayer', k.product_id, 'tcgp_checked', current_date::text), 'normal', 'Promo');
      insert into tcgp_reconcile_log(applied, set_id, action, product_id, detail) values (true, p_set, 'add_promo', k.product_id, k.number || ' ' || k.name || ' [' || vlabel || ']');
    end if;
  end loop;
  return n;
end $_$;


ALTER FUNCTION "public"."add_promo_printings"("p_set" bigint, "p_apply" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."adjust_collection"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_delta" integer) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare uid uuid := auth.uid(); r record; remaining int; total int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_delta > 0 then
    select id into r from collection_items where owner_id = uid and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'') order by id limit 1;
    if found then update collection_items set quantity = quantity + p_delta where id = r.id;
    else insert into collection_items (owner_id, product_id, condition, grade, quantity, date_added) values (uid, p_product, p_condition, coalesce(p_grade,''), p_delta, current_date);
    end if;
  elsif p_delta < 0 then
    remaining := -p_delta;
    select coalesce(sum(quantity),0) into total from collection_items where owner_id = uid and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'');
    if total < remaining then raise exception 'You only have % of this item in that condition', total; end if;
    for r in select id, quantity from collection_items where owner_id = uid and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'') order by id loop
      exit when remaining = 0;
      if r.quantity <= remaining then delete from collection_items where id = r.id; remaining := remaining - r.quantity;
      else update collection_items set quantity = quantity - remaining where id = r.id; remaining := 0; end if;
    end loop;
  end if;
  select coalesce(sum(quantity),0) into total from collection_items where owner_id = uid and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'');
  return total;
end $$;


ALTER FUNCTION "public"."adjust_collection"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_delta" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apitcg_get"("path" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'vault'
    AS $$
  select content::jsonb from extensions.http((
    'GET', 'https://api.apitcg.com' || path,
    array[extensions.http_header('x-api-key', (select decrypted_secret from vault.decrypted_secrets where name = 'apitcg_key'))],
    null, null)::extensions.http_request)
$$;


ALTER FUNCTION "public"."apitcg_get"("path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ask_lot_flag"("title" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case when title ~* '(^|[^0-9a-z])([2-9]|[1-9][0-9]+)\s*x([^a-z0-9]|$)'
                or title ~* '\m(lots|bundles|boxes|tins|etbs)\M'
              then 'Title suggests multiple items / a lot' end $_$;


ALTER FUNCTION "public"."ask_lot_flag"("title" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ask_title_flag"("title" "text", "grade" "text", "num" "text", "lang" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select coalesce(sold_title_flag(title, grade), ask_lot_flag(title),
    case when num ~ '^\d+$' and title !~* ('(^|[^0-9])0*' || ltrim(num,'0') || '([^0-9]|$)') then 'Card number not in title'
         when num !~ '^\d*$' and position(lower(replace(num,'-','')) in lower(replace(title,'-',''))) = 0 then 'Card code not in title'
         when lang = 'EN' and title ~* '\m(japanese|jpn|japan|korean|chinese)\M' then 'Different language'
         when lang = 'JP' and title !~* '\m(japanese|jpn|japan|jp)\M' then 'Not marked Japanese'
    end) $_$;


ALTER FUNCTION "public"."ask_title_flag"("title" "text", "grade" "text", "num" "text", "lang" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_card_variants"("p_tid" "text", "p_lang" "text" DEFAULT 'en'::"text") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare j jsonb; st int; n int;
begin
  begin
    select status, content::jsonb into st, j from extensions.http_get('https://api.tcgdex.net/v2/' || p_lang || '/cards/' || p_tid);
  exception when others then return -1;   -- TCGdex timeout: try again on a later pass
  end;
  if st <> 200 or j is null or jsonb_array_length(coalesce(j->'variants_detailed', '[]'::jsonb)) = 0 then return 0; end if;
  insert into variant_audit (product_id, tcgdex_id, set_code, card_number, name, our_variant, verdict, new_label, owned)
  select p.id, p_tid, s.code, p.card_number, p.name, p.variant,
         case when exists (select 1 from tcgdex_variant_labels(j->'variants_detailed') l where l.label = p.variant) then 'ok'
              when x.label is not null then 'relabel' else 'unverified' end,
         x.label, (select count(*) from collection_items c where c.product_id = p.id)
  from products p join sets s on s.id = p.set_id
  left join lateral (
    -- a plain "Holofoil"/"Normal" line that matches exactly one exclusive printing of the same finish
    select min(l.label) label from tcgdex_variant_labels(j->'variants_detailed') l
    where l.kind = 'exclusive' and (case when p.variant = 'Holofoil' then l.label like 'Holofoil (%' when p.variant = 'Normal' then l.label like 'Non-Holofoil (%' or l.label like 'Normal (%' end)
      and not exists (select 1 from products q where q.set_id = p.set_id and card_key(q.card_number) = card_key(p.card_number) and q.language = p.language and q.variant = l.label)
    having count(*) = 1) x on true
  where p.set_id = (select set_id from products where external_ids->>'tcgdex' = p_tid limit 1)
    and card_key(p.card_number) = card_key(split_part(p_tid, '-', 2)) and p.kind = 'card' and p.variant <> ''
  on conflict (product_id) do update set verdict = excluded.verdict, new_label = excluded.new_label, owned = excluded.owned, our_variant = excluded.our_variant, checked_at = now();
  get diagnostics n = row_count;
  return n;
end $$;


ALTER FUNCTION "public"."audit_card_variants"("p_tid" "text", "p_lang" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_variants_batch"("max_n" integer DEFAULT 30) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare r record; n int := 0; lines int := 0; k int;
begin
  for r in select c.tid, c.lang from variant_audit_candidates c
           where not exists (select 1 from variant_audit a where a.tcgdex_id = c.tid and a.checked_at > now() - interval '30 days') order by c.tid limit max_n loop
    k := audit_card_variants(r.tid, r.lang);
    if k = 0 then   -- no detailed variants at TCGdex: record it so the queue moves on
      insert into variant_audit (product_id, tcgdex_id, verdict)
      select p.id, r.tid, 'no_detail' from products p where p.external_ids->>'tcgdex' = r.tid order by p.id limit 1
      on conflict (product_id) do nothing;
    end if;
    n := n + 1; lines := lines + greatest(k, 0);
  end loop;
  return jsonb_build_object('cards', n, 'lines', lines, 'left', (select count(*) from variant_audit_candidates c where not exists (select 1 from variant_audit a where a.tcgdex_id = c.tid and a.checked_at > now() - interval '30 days')));
end $$;


ALTER FUNCTION "public"."audit_variants_batch"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."avg_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  select case when sum(quantity) filter (where cost_paid is not null) > 0
         then round(sum(cost_paid * quantity) filter (where cost_paid is not null) / sum(quantity) filter (where cost_paid is not null), 2) end
  from collection_items where owner_id = p_owner and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'')
$$;


ALTER FUNCTION "public"."avg_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."backfill_portfolio"("p_weeks" integer DEFAULT 13) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare w int; d date; n int := 0; k int;
begin
  for w in 1..p_weeks loop
    d := current_date - 7 * w;
    insert into portfolio_snapshots (owner_id, day, set_id, game_id, kind, language, items, value, priced_items, source)
    select owner_id, d, set_id, game_id, kind, language, sum(quantity), coalesce(sum(quantity * px), 0),
           coalesce(sum(case when px is not null then quantity end), 0), 'backfill'
    from (select c.owner_id, coalesce(p.set_id, 0) set_id, p.game_id, p.kind, p.language, c.quantity,
                 price_as_of(c.product_id, c.condition, c.grade, p.kind, d) px
          from collection_items c join products p on p.id = c.product_id
          where c.owner_id is not null and coalesce(c.date_added, date '1900-01-01') <= d) x
    group by owner_id, set_id, game_id, kind, language
    on conflict (owner_id, day, set_id, kind, language) do update
      set items = excluded.items, value = excluded.value, priced_items = excluded.priced_items
      where portfolio_snapshots.source = 'backfill';
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."backfill_portfolio"("p_weeks" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."blend_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text", "p_added" integer, "p_price" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare r record;
begin
  if p_price is null then return; end if;
  select id, quantity, cost_paid into r from collection_items
  where owner_id = p_owner and product_id = p_product and condition = p_condition and grade = coalesce(p_grade,'') order by id limit 1;
  if not found then return; end if;
  update collection_items set cost_paid = case
      when r.cost_paid is null or r.quantity <= p_added then p_price
      else round((r.cost_paid * (r.quantity - p_added) + p_price * p_added) / r.quantity, 2) end
  where id = r.id;
end $$;


ALTER FUNCTION "public"."blend_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text", "p_added" integer, "p_price" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulba_entry_name"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  with x as (select regexp_replace(t, '^(?:[^|{\[]*\|)?', '') b)
  select coalesce(
    (select case when n ilike '%' || trim(both ' -' from sfx) and sfx <> '' then n else n || sfx end
       from (select substring(b from '^\{\{TCG ID\|[^|]+\|([^|}]+)') n, bulba_name_suffix(b) sfx) y where n is not null),
    nullif(regexp_replace(substring(b from '^\[\[([^|\]]+)'), '\s*\([^)]*\)$', ''), ''),
    substring(b from '\{\{TCG ID\|[^|]+\|([^|}]+)'),
    substring(b from '^\{\{TCG\|([^|}]+)')) from x $_$;


ALTER FUNCTION "public"."bulba_entry_name"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulba_list_entries"("w" "text") RETURNS TABLE("seg" integer, "title" "text", "ord" integer, "nm" "text")
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select x.i::int, substring(x.s from '^title=([^|}]+)'), (row_number() over (partition by x.i order by e.o))::int, bulba_entry_name(e.m[2])
  from regexp_split_to_table(w, '\{\{[Ss]etlist/[a-z]*header\|') with ordinality x(s, i),
       regexp_matches(x.s, '\{\{[Ss]etlist/[a-z]*entry\|([^|}\n]*)\|([^\n]*)', 'g') with ordinality e(m, o)
  where coalesce(substring(x.s from '^title=([^|}]+)'), '') !~* 'additional|error|promo' $$;


ALTER FUNCTION "public"."bulba_list_entries"("w" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulba_logo"("p_prefix" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $_$
declare j jsonb;
begin
  j := (select content::jsonb from extensions.http_get('https://archives.bulbagarden.net/w/api.php?action=query&format=json&list=allimages&ailimit=50&aiprop=url&aiprefix=' || extensions.urlencode(p_prefix)));
  return (select x->>'url' from jsonb_array_elements(j->'query'->'allimages') x
          where x->>'name' ~* '_logo(_en)?\.png$' and x->>'name' !~* '(pack|box|_sc|_tc|_kr|_th|_id|zh|chinese|korean)' order by length(x->>'name') limit 1);
exception when others then return null;
end $_$;


ALTER FUNCTION "public"."bulba_logo"("p_prefix" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulba_name_suffix"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case (regexp_match(coalesce(substring(t from '^(?:\{\{TCG ID\|[^}]*\}\}|\[\[[^\]]*\]\])\{\{([A-Za-z .-]+)\}\}'), ''), '([A-Za-z.-]+)$'))[1]
    when 'ex' then ' ex' when 'EX' then '-EX' when 'GX' then '-GX' when 'V' then ' V' when 'VMAX' then ' VMAX'
    when 'VSTAR' then ' VSTAR' when 'V-UNION' then ' V-UNION' when 'BREAK' then ' BREAK' when 'LVX' then ' LV.X'
    when 'Star' then ' ☆' else '' end $_$;


ALTER FUNCTION "public"."bulba_name_suffix"("t" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."sets" (
    "id" bigint NOT NULL,
    "game_id" "text" NOT NULL,
    "series_id" bigint,
    "name" "text" NOT NULL,
    "code" "text",
    "release_date" "date",
    "language" "text" DEFAULT 'EN'::"text" NOT NULL,
    "synced_at" timestamp with time zone,
    "sync_attempts" integer DEFAULT 0 NOT NULL,
    "sync_note" "text",
    "logo_url" "text",
    "cover_url" "text",
    "hidden" boolean DEFAULT false NOT NULL,
    "name_jp" "text"
);


ALTER TABLE "public"."sets" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulba_page_for"("s" "public"."sets") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $_$
  select case
    when s.language = 'JP' then case
      when s.name ~* '^Pok[eé]mon 151' then 'Pokémon Card 151 (TCG)'
      when s.code = 'VS1' then 'Pokémon VS (TCG)'
      when s.code = 'web1' then 'Pokémon Web (TCG)'
      else regexp_replace(s.name, '\s*\(JP\)$', '') || ' (TCG)' end
    when s.code = 'sv01' then 'Scarlet & Violet (TCG)'
    when s.code = 'sv03.5' then '151 (TCG)'
    when s.code = 'swsh1' then 'Sword & Shield (TCG)'
    when s.code = 'sm1' then 'Sun & Moon (TCG)'
    when s.code = 'xy1' then 'XY (TCG)'
    when s.code = 'bw1' then 'Black & White (TCG)'
    when s.code = 'dp1' then 'Diamond & Pearl (TCG)'
    when s.code = 'pl1' then 'Platinum (TCG)'
    when s.code = 'hgss1' then 'HeartGold & SoulSilver (TCG)'
    when s.code = 'ex1' then 'EX Ruby & Sapphire (TCG)'
    when s.code = 'me01' then 'Mega Evolution (TCG)'
    when s.code like 'swsh%tg' then regexp_replace(s.name, '\s*Trainer Gallery$', '') || ' (TCG)'
    when s.code = 'swsh12.5gg' then 'Crown Zenith (TCG)'
    when s.code = 'swsh4.5sv' then 'Shining Fates (TCG)'
    when s.code = 'sma' then 'Hidden Fates (TCG)'
    when s.code ~ '^ex\d' and s.name not like 'EX %' then 'EX ' || s.name || ' (TCG)'
    else s.name || ' (TCG)' end $_$;


ALTER FUNCTION "public"."bulba_page_for"("s" "public"."sets") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cap_words"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select string_agg(upper(left(w,1)) || substr(w,2), ' ' order by o) from regexp_split_to_table(btrim(t), '\s+') with ordinality x(w,o) $$;


ALTER FUNCTION "public"."cap_words"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."card_key"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select regexp_replace(upper(regexp_replace(split_part(coalesce(t,''),'/',1),'[^A-Za-z0-9]','','g')), '^([A-Z]*)0+([0-9])', '\1\2') $$;


ALTER FUNCTION "public"."card_key"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."catalog_series_name"("tcg" "text", "code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when tcg = 'dragon-ball-super-fusion-world' then 'Fusion World'
    when tcg = 'dragon-ball-super-masters' then 'Masters (original DBS)'
    when code ~* '^PRB' then 'Premium boosters (PRB)'
    when code ~* '^OP' then 'Main boosters (OP)'
    when code ~* '^EB' then 'Extra boosters (EB)'
    when code ~* '^ST' then 'Starter decks (ST)'
    else 'Promos & other' end
$$;


ALTER FUNCTION "public"."catalog_series_name"("tcg" "text", "code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."catalog_stats"("p_games" "text"[] DEFAULT NULL::"text"[], "p_lang" "text" DEFAULT NULL::"text", "p_kind" "text" DEFAULT NULL::"text", "p_series" bigint[] DEFAULT NULL::bigint[], "p_sets" bigint[] DEFAULT NULL::bigint[], "p_owned" boolean DEFAULT NULL::boolean, "p_q" "text" DEFAULT NULL::"text", "p_special" "text"[] DEFAULT NULL::"text"[], "p_cond" "text" DEFAULT 'NM'::"text", "p_grade" "text" DEFAULT ''::"text") RETURNS json
    LANGUAGE "sql" STABLE
    AS $$
  with f as (
    select c.* from catalog_v c
    where (p_games is null or c.game_id = any(p_games))
      and (p_lang is null or c.language = p_lang)
      and (p_kind is null or c.kind = p_kind)
      and (p_sets is null or c.set_id = any(p_sets))
      and (p_sets is not null or p_series is null or c.series_id = any(p_series))
      and (p_owned is null or c.owned = p_owned)
      and (p_special is null or c.special = any(p_special))
      and (p_q is null or c.name ilike '%' || p_q || '%' or c.card_number ilike '%' || p_q || '%')
  ), priced as (
    select f.id, f.owned,
      case when f.kind = 'sealed' then (select max(median) from price_v v where v.product_id = f.id and v.condition in ('Sealed','NM') and v.grade = '')
           when coalesce(p_grade,'') <> '' then (select max(median) from price_v v where v.product_id = f.id and v.grade = p_grade)
           else (select median from price_v v where v.product_id = f.id and v.condition = coalesce(p_cond,'NM') and v.grade = '') end as px
    from f
  )
  select json_build_object('count', count(*), 'value', coalesce(sum(px), 0), 'priced', count(px),
    'owned', count(*) filter (where owned), 'owned_value', coalesce(sum(px) filter (where owned), 0)) from priced
$$;


ALTER FUNCTION "public"."catalog_stats"("p_games" "text"[], "p_lang" "text", "p_kind" "text", "p_series" bigint[], "p_sets" bigint[], "p_owned" boolean, "p_q" "text", "p_special" "text"[], "p_cond" "text", "p_grade" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_alerts"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare a record; now_p numeric; past_p numeric; pname text; n int := 0; msg text;
begin
  for a in select * from price_alerts where active and (last_triggered_at is null or last_triggered_at < now() - interval '20 hours') loop
    select median into now_p from price_v where product_id = a.product_id and condition = a.condition and grade = a.grade;
    continue when now_p is null;
    select name into pname from products where id = a.product_id;
    msg := null;
    if a.kind = 'below' and now_p <= a.threshold then msg := pname || ' is now $' || now_p || ' (at or below your $' || a.threshold || ' target)';
    elsif a.kind = 'above' and now_p >= a.threshold then msg := pname || ' is now $' || now_p || ' (at or above your $' || a.threshold || ' target)';
    elsif a.kind = 'move' then
      past_p := price_as_of(a.product_id, a.condition, a.grade, (select kind from products where id = a.product_id), current_date - 7);
      if past_p > 0 and abs(now_p - past_p) / past_p * 100 >= a.threshold then
        msg := pname || ' moved ' || case when now_p > past_p then 'up ' else 'down ' end || round(abs(now_p - past_p) / past_p * 100) || '% in a week (now $' || now_p || ')';
      end if;
    end if;
    if msg is not null then
      insert into alert_events (owner_id, alert_id, product_id, message, price) values (a.owner_id, a.id, a.product_id, msg, now_p);
      update price_alerts set last_triggered_at = now() where id = a.id; n := n + 1;
    end if;
  end loop;
  return n;
end $_$;


ALTER FUNCTION "public"."check_alerts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_insights_access"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare res text;
begin
  begin
    perform ebay_token('https://api.ebay.com/oauth/api_scope/buy.marketplace.insights');
    res := 'GRANTED';
  exception when others then
    res := case when sqlerrm like '%invalid_scope%' then 'not granted' else 'check failed: ' || left(sqlerrm, 120) end;
  end;
  insert into sync_log (game_id, items, note) values (null, 0, 'ebay insights access: ' || res);
  return res;
end $$;


ALTER FUNCTION "public"."check_insights_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_magic_counts"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into set_count_check (set_id, game_id, source, expected, ours)
  select s.id, 'magic', 'scryfall', sf.cnt,
         (select count(distinct coalesce(p.external_ids->>'scryfall', p.id::text)) from products p where p.set_id = s.id and p.kind = 'card')
  from jsonb_array_elements((select content::jsonb from extensions.http_get('https://api.scryfall.com/sets'))->'data') x
  cross join lateral (select x->>'code' code, (x->>'card_count')::int cnt) sf
  join sets s on s.game_id = 'magic' and s.code = sf.code
  on conflict (set_id) do update set expected = excluded.expected, ours = excluded.ours, checked_at = now();
  return (select jsonb_build_object('exact', count(*) filter (where ours = expected), 'short', count(*) filter (where ours < expected),
                                    'cards_short', sum(expected - ours) filter (where ours < expected)) from set_count_check where game_id = 'magic');
end $$;


ALTER FUNCTION "public"."check_magic_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_ygo_counts"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into set_count_check (set_id, game_id, source, expected, ours)
  select s.id, 'yugioh', 'ygoprodeck', y.cnt,
         (select count(distinct p.card_number) from products p where p.set_id = s.id and p.kind = 'card')
  from (select x->>'set_name' name, max((x->>'num_of_cards')::int) cnt
        from jsonb_array_elements((select content::jsonb from extensions.http_get('https://db.ygoprodeck.com/api/v7/cardsets.php'))) x group by 1) y
  join sets s on s.game_id = 'yugioh' and replace(s.name, '''', '&apos;') = replace(y.name, '''', '&apos;')
  on conflict (set_id) do update set expected = excluded.expected, ours = excluded.ours, checked_at = now();
  return (select jsonb_build_object('exact', count(*) filter (where ours = expected), 'short', count(*) filter (where ours < expected),
                                    'cards_short', sum(expected - ours) filter (where ours < expected)) from set_count_check where game_id = 'yugioh');
end $$;


ALTER FUNCTION "public"."check_ygo_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checklist_num_ok"("code" "text", "num" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when code like 'swsh%tg' then num ~ '^TG'
    when code = 'swsh12.5gg' then num ~ '^GG'
    when code in ('swsh4.5sv','sma') then num ~ '^SV'
    when code in ('swsh9','swsh10','swsh11','swsh12') then num !~ '^TG'
    when code = 'swsh12.5' then num !~ '^GG'
    when code in ('swsh4.5','sm115') then num !~ '^SV'
    else true end $$;


ALTER FUNCTION "public"."checklist_num_ok"("code" "text", "num" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."classify_special"("set_name" "text", "name" "text", "variant" "text", "rarity" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when t ~* 'pre-?release' then 'Prerelease'
    when t ~* '(championship|worlds|tournament|prize|top ?cut|regional|winner|judge|staff|finalist)' then 'Tournament & prize'
    when t ~* '(jumbo|oversize)' then 'Jumbo'
    when t ~* '(promo|black star|promotion)' then 'Promo'
  end
  from (select coalesce(set_name,'') || ' ' || coalesce(name,'') || ' ' || coalesce(variant,'') || ' ' || coalesce(rarity,'') as t) x
$$;


ALTER FUNCTION "public"."classify_special"("set_name" "text", "name" "text", "variant" "text", "rarity" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_cart"("p_cart" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare c record; i record; me uuid := auth.uid();
begin
  select * into c from carts where id = p_cart and owner_id = me;
  if not found then raise exception 'Cart not found'; end if;
  if c.status <> 'open' then raise exception 'This cart is already completed'; end if;
  update cart_items ci set unit_price = coalesce(ci.unit_price, p.median)
  from price_v p where ci.cart_id = p_cart and p.product_id = ci.product_id and p.condition = ci.condition and p.grade = ci.grade;
  for i in select * from cart_items where cart_id = p_cart and side = 'sell' loop
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, unit_price, unit_cost, source, ref_id)
    values (me, i.product_id, i.condition, i.grade, 'out', i.quantity, i.unit_price, avg_cost(me, i.product_id, i.condition, i.grade), 'cart', p_cart);
    perform adjust_collection(i.product_id, i.condition, i.grade, -i.quantity);
  end loop;
  for i in select * from cart_items where cart_id = p_cart and side = 'buy' loop
    perform adjust_collection(i.product_id, i.condition, i.grade, i.quantity);
    perform blend_cost(me, i.product_id, i.condition, i.grade, i.quantity, i.unit_price);
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, unit_price, source, ref_id)
    values (me, i.product_id, i.condition, i.grade, 'in', i.quantity, i.unit_price, 'cart', p_cart);
  end loop;
  update carts set status = 'completed', completed_at = now() where id = p_cart;
end $$;


ALTER FUNCTION "public"."complete_cart"("p_cart" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ebay_browse_token"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'vault'
    AS $$
declare t record; cid text; sec text; resp record; body jsonb; sc text := 'https://api.ebay.com/oauth/api_scope';
begin
  select * into t from ebay_auth where id = 2;
  if found and t.token is not null and t.expires_at > now() + interval '5 minutes' then return t.token; end if;
  select decrypted_secret into cid from vault.decrypted_secrets where name = 'ebay_client_id';
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'ebay_client_secret';
  if cid is null or sec is null then raise exception 'eBay keys missing from Vault'; end if;
  perform http_setup();
  select * into resp from extensions.http(('POST', 'https://api.ebay.com/identity/v1/oauth2/token',
    array[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(trim(cid) || ':' || trim(sec), 'UTF8'), 'base64'), E'\n', ''))],
    'application/x-www-form-urlencoded', 'grant_type=client_credentials&scope=' || extensions.urlencode(sc))::extensions.http_request);
  if resp.status <> 200 then raise exception 'eBay token error %: %', resp.status, left(resp.content, 300); end if;
  body := resp.content::jsonb;
  insert into ebay_auth (id, token, expires_at, scope) values (2, body->>'access_token', now() + make_interval(secs => (body->>'expires_in')::int), sc)
  on conflict (id) do update set token = excluded.token, expires_at = excluded.expires_at, scope = excluded.scope;
  return body->>'access_token';
end $$;


ALTER FUNCTION "public"."ebay_browse_token"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ebay_get"("url" "text") RETURNS "record"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare resp record;
begin
  perform http_setup();
  select status, content into resp from extensions.http(('GET', url,
    array[extensions.http_header('Authorization', 'Bearer ' || ebay_token()), extensions.http_header('X-EBAY-C-MARKETPLACE-ID', 'EBAY_AU')],
    null, null)::extensions.http_request);
  return resp;
end $$;


ALTER FUNCTION "public"."ebay_get"("url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ebay_token"("p_scope" "text" DEFAULT 'https://api.ebay.com/oauth/api_scope/buy.marketplace.insights'::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'vault'
    AS $$
declare t record; cid text; sec text; resp record; body jsonb;
begin
  select * into t from ebay_auth where id = 1;
  if found and t.token is not null and t.expires_at > now() + interval '5 minutes' and t.scope = p_scope then return t.token; end if;
  select decrypted_secret into cid from vault.decrypted_secrets where name = 'ebay_client_id';
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'ebay_client_secret';
  if cid is null or sec is null then raise exception 'eBay keys missing from Vault'; end if;
  perform http_setup();
  select * into resp from extensions.http((
    'POST', 'https://api.ebay.com/identity/v1/oauth2/token',
    array[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(trim(cid) || ':' || trim(sec), 'UTF8'), 'base64'), E'\n', ''))],
    'application/x-www-form-urlencoded',
    'grant_type=client_credentials&scope=' || extensions.urlencode(p_scope))::extensions.http_request);
  if resp.status <> 200 then raise exception 'eBay token error %: %', resp.status, left(resp.content, 300); end if;
  body := resp.content::jsonb;
  insert into ebay_auth (id, token, expires_at, scope) values (1, body->>'access_token', now() + make_interval(secs => (body->>'expires_in')::int), p_scope)
  on conflict (id) do update set token = excluded.token, expires_at = excluded.expires_at, scope = excluded.scope;
  return body->>'access_token';
end $$;


ALTER FUNCTION "public"."ebay_token"("p_scope" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enrich_pokemon_cards"("max_cards" integer DEFAULT 40, "p_set_code" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare
  rf text[];
  c record; r record; j jsonb; st int; rar text; official text; vars text[]; prim text; tnum text; tvar text; dup bigint; done int := 0; v text;
begin
  if not pg_try_advisory_lock(424242) then return 0; end if;
  for c in
    select p.external_ids->>'tcgdex' tid, case when s.language='JP' then 'ja' else 'en' end lang,
           bool_or(p.rarity is null or coalesce(p.variant,'')='') blank
    from products p join sets s on s.id=p.set_id
    where p.game_id='pokemon' and p.kind='card' and p.external_ids ? 'tcgdex'
      and (not (p.external_ids ? 'tcgdex_detail') or p.external_ids->>'tcgdex_detail' like 'error%'
           or (s.release_date > current_date - 180 and p.external_ids->>'tcgdex_detail' ~ '^\d{4}-\d{2}-\d{2}$'
               and (p.external_ids->>'tcgdex_detail')::date < current_date - 14)) and (p_set_code is null or s.code = p_set_code)
    group by 1,2 order by bool_or(p.external_ids->>'tcgdex_detail' like 'error%'),
             bool_or(p.variant = 'Reverse Holofoil') desc,  -- generic reverse lines waiting to be split into patterns go first
             3 desc, 1 limit max_cards
  loop
    begin
      select status, content::jsonb into st, j from extensions.http_get('https://api.tcgdex.net/v2/' || c.lang || '/cards/' || c.tid);
      if st <> 200 or j is null then
        update products set external_ids = external_ids || jsonb_build_object('tcgdex_detail', 'not_found ' || current_date)
         where external_ids->>'tcgdex' = c.tid and game_id='pokemon';
        continue;
      end if;
      rar := cap_words(nullif(j->>'rarity','None'));
      official := j->'set'->'cardCount'->>'official';
      vars := array[]::text[];
      if (j->'variants'->>'normal')::boolean then vars := array_append(vars, 'Normal'); end if;
      if (j->'variants'->>'holo')::boolean then vars := array_append(vars, 'Holofoil'); end if;
      if (j->'variants'->>'firstEdition')::boolean then vars := array_append(vars, '1st Edition'); end if;
      if (j->'variants'->>'reverse')::boolean then vars := array_append(vars, 'Reverse Holofoil'); end if;
      -- prefer variants_detailed: the yes/no flags also switch on for merch exclusives and stamped cards
      if jsonb_array_length(coalesce(j->'variants_detailed', '[]'::jsonb)) > 0 then
        vars := array(select l.label from tcgdex_variant_labels(j->'variants_detailed') l
                      where l.kind = 'booster'  -- exclusives (Cosmos holos, theme-deck non-holos) are not part of the set
                      order by l.kind <> 'booster', case when l.label = 'Normal' then 0 when l.label = 'Holofoil' then 1
                               when l.label = '1st Edition' then 2 when l.label like 'Reverse%' then 3 else 4 end, l.label);
        if coalesce(array_length(vars, 1), 0) = 0 then vars := array['Normal']; end if;
      end if;
      prim := coalesce(vars[1], 'Normal');
      -- several reverse-holo patterns: one product each; the generic reverse product becomes the first pattern
      rf := array(select x.v->>'foil' from jsonb_array_elements(coalesce(j->'variants_detailed', '[]'::jsonb)) with ordinality x(v, i)
                  where x.v->>'type' = 'reverse' and coalesce(x.v->>'foil', '') <> '' order by x.i);
      if coalesce(array_length(rf, 1), 0) > 1 then
        update products q set variant = reverse_pattern_label(rf[1])
         from (select set_id, card_key(card_number) ck, language from products where external_ids->>'tcgdex' = c.tid and game_id = 'pokemon' and kind = 'card' limit 1) k
         where q.set_id = k.set_id and card_key(q.card_number) = k.ck and q.language = k.language and q.kind = 'card' and q.variant = 'Reverse Holofoil'
           -- keep the plain reverse line when TCGplayer lists a plain reverse for this card
           and (q.language <> 'EN' or not exists (select 1 from tcgp_keys t where t.set_id = q.set_id and t.num = tcgp_num(q.card_number)
                                                   and t.sub_type = 'Reverse Holofoil' and t.pattern = ''))
           and not exists (select 1 from products z where z.set_id = k.set_id and card_key(z.card_number) = k.ck and z.language = k.language and z.variant = reverse_pattern_label(rf[1]));
        vars := array_remove(vars, 'Reverse Holofoil');
        vars := vars || array(select reverse_pattern_label(f) from unnest(rf) f where not (reverse_pattern_label(f) = any(vars)));
      end if;

      for r in select * from products where external_ids->>'tcgdex' = c.tid and game_id='pokemon' and kind='card' order by id loop
        if c.tid ~* '^swsh' and r.card_number ~ '^\d{1,2}$' then r.card_number := lpad(r.card_number, 3, '0'); end if;
        tnum := case when r.card_number !~ '/' and r.card_number ~ '^\d+$' and coalesce(official,'') ~ '^\d+$' and official::int > 0
                     then r.card_number || '/' || lpad(official, greatest(length(official), length(r.card_number)), '0') else r.card_number end;
        tvar := case when coalesce(r.variant,'') = '' then prim else r.variant end;
        select id into dup from products q where q.id <> r.id and q.game_id=r.game_id and q.set_id=r.set_id and q.name=r.name
           and q.card_number=tnum and q.variant=tvar and q.language=r.language limit 1;
        if dup is not null then
          perform merge_product(r.id, dup);
          update products set rarity = coalesce(rarity, rar),
                 external_ids = external_ids || jsonb_build_object('tcgdex', c.tid, 'tcgdex_detail', current_date::text) where id = dup;
        else
          update products set card_number = tnum, variant = tvar, rarity = coalesce(rarity, rar),
                 external_ids = external_ids || jsonb_build_object('tcgdex_detail', current_date::text) where id = r.id;
        end if;
      end loop;

      -- add any variant TCGdex lists that we don't hold yet
      foreach v in array vars loop
        insert into products (game_id, set_id, kind, name, name_jp, card_number, rarity, variant, language, image_url, external_ids, price_tier)
        select p.game_id, p.set_id, p.kind, p.name, p.name_jp, p.card_number, p.rarity, v, p.language, p.image_url,
               jsonb_build_object('tcgdex', c.tid, 'tcgdex_detail', current_date::text), p.price_tier
        from products p where p.external_ids->>'tcgdex' = c.tid and p.game_id='pokemon' and p.kind='card'
          and not exists (select 1 from products q where q.set_id=p.set_id and card_key(q.card_number)=card_key(p.card_number)
                            and q.variant = v and q.language=p.language)
          and (p.language <> 'EN' or tcgp_allows(p.set_id, p.card_number, v))
        order by p.id limit 1
        on conflict do nothing;
      end loop;
      done := done + 1;
      perform pg_sleep(0.05);
    exception when others then
      update products set external_ids = external_ids || jsonb_build_object('tcgdex_detail', 'error ' || left(sqlerrm, 80))
       where external_ids->>'tcgdex' = c.tid and game_id='pokemon';
    end;
  end loop;
  perform pg_advisory_unlock(424242);
  insert into sync_log (game_id, items, note) values ('pokemon', done, 'enrich_pokemon_cards');
  return done;
end $_$;


ALTER FUNCTION "public"."enrich_pokemon_cards"("max_cards" integer, "p_set_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_ask_prices"("max_q" integer DEFAULT 15) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  k record; it jsonb; resp record; body jsonb; q text; cat text; url text; started timestamptz; done int := 0;
  pid bigint; want text; g text; cond text; flag text; numchk text; used int;
begin
  if not pg_try_advisory_lock(515151) then return 0; end if;
  perform http_setup();
  for k in
    with own as (select distinct product_id from collection_items),
    keyed as (
      select p.id, p.game_id, p.set_id, p.language, p.kind, p.variant, p.card_number, s.name set_name, s.release_date,
             regexp_replace(p.name, '\s*[\(\[].*?[\)\]]', '', 'g') base, (o.product_id is not null) owned,
             case when p.kind = 'card'
                  then p.game_id||'|'||p.set_id||'|'||card_key(p.card_number)||'|'||lower(regexp_replace(p.name, '\s*[\(\[].*?[\)\]]', '', 'g'))
                  else 'sealed|'||p.id end qkey
      from products p join sets s on s.id = p.set_id left join own o on o.product_id = p.id
      where p.kind in ('card','sealed') and coalesce(s.hidden,false) = false),
    g2 as (
      select qkey, game_id, set_id, language, kind, min(base) base, min(card_number) num, min(set_name) set_name, max(release_date) rel,
             bool_or(owned) owned,
             array_agg(id order by (variant in ('Normal','Holofoil')) desc, id) ids,
             array_agg(variant order by (variant in ('Normal','Holofoil')) desc, id) vars
      from keyed group by qkey, game_id, set_id, language, kind)
    select g2.* from g2 left join ask_fetch_state f on f.qkey = g2.qkey
    where f.last_fetched is null or f.last_fetched < now() - case when g2.owned then interval '4 days' else interval '30 days' end
    order by g2.owned desc,
             case g2.game_id when 'pokemon' then 1 when 'dragon-ball' then 2 when 'one-piece' then 3 else 4 end,
             g2.rel desc nulls last, g2.qkey
    limit max_q
  loop
    select coalesce(requests,0) into used from api_usage where day = current_date and source = 'ebay_browse';
    exit when coalesce(used,0) >= 4500;      -- Browse API default allowance is 5,000 calls/day
    started := now();
    q := case
      when k.kind = 'sealed' then k.base
      when k.game_id = 'magic' then k.base || ' ' || k.set_name
      when k.game_id = 'yugioh' then k.num || ' ' || k.base
      else k.base || ' ' || coalesce(k.num,'') end
      || case when k.language = 'JP' then ' japanese' else '' end;
    numchk := case when k.kind = 'sealed' or k.game_id = 'magic' then ''
                   when k.game_id = 'pokemon' then regexp_replace(split_part(coalesce(k.num,''),'/',1), '\D', '', 'g')
                   else coalesce(k.num,'') end;
    cat := case when k.kind = 'sealed' then '2536' else '183454' end;
    url := 'https://api.ebay.com/buy/browse/v1/item_summary/search?q=' || urlencode(left(q, 95)) || '&category_ids=' || cat
           || '&limit=50&filter=' || urlencode('buyingOptions:{FIXED_PRICE},itemLocationCountry:AU');
    begin
      select status, content into resp from extensions.http(('GET', url,
        array[extensions.http_header('Authorization','Bearer '||ebay_browse_token()), extensions.http_header('X-EBAY-C-MARKETPLACE-ID','EBAY_AU')],
        null, null)::extensions.http_request);
      insert into api_usage (day, source, requests) values (current_date, 'ebay_browse', 1)
      on conflict (day, source) do update set requests = api_usage.requests + 1;
      if resp.status <> 200 then raise exception 'browse %: %', resp.status, left(resp.content, 120); end if;
      body := resp.content::jsonb;

      for it in select * from jsonb_array_elements(coalesce(body->'itemSummaries','[]'::jsonb)) loop
        g := case when k.kind = 'sealed' then '' else grade_from_title(it->>'title') end;
        cond := case when k.kind = 'sealed' then 'Sealed' else 'NM' end;
        want := case
          when it->>'title' ~* 'reverse' then 'Reverse Holofoil'
          when it->>'title' ~* '1st ed' then '1st Edition'
          when it->>'title' ~* 'parallel' then 'Parallel'
          when it->>'title' ~* 'alt(ernate)?[ .-]?art' then 'Alternate Art'
          when it->>'title' ~* 'manga' then 'Manga'
          when k.game_id = 'magic' and it->>'title' ~* 'etched' then 'Etched Foil'
          when k.game_id = 'magic' and it->>'title' ~* 'foil' then 'Foil'
        end;
        pid := null;
        if want is not null then
          select k.ids[i] into pid from generate_subscripts(k.ids, 1) i where k.vars[i] = want limit 1;
          continue when pid is null;            -- e.g. a "reverse" listing when we hold no reverse variant
        else
          pid := k.ids[1];                      -- Normal / Holofoil first
        end if;
        flag := case when k.kind = 'sealed' then sealed_title_flag(it->>'title', k.base) else ask_title_flag(it->>'title', g, numchk, k.language) end;
        insert into ask_listings (product_id, market, condition, grade, price, currency, title, url, image_url, ebay_item_id, excluded, exclusion_reason, last_seen)
        values (pid, 'AU', cond, g, (it->'price'->>'value')::numeric, it->'price'->>'currency', it->>'title', it->>'itemWebUrl',
                it->'image'->>'imageUrl', it->>'itemId', flag is not null, flag, now())
        on conflict (product_id, ebay_item_id) do update set price = excluded.price, title = excluded.title, grade = excluded.grade,
               excluded = excluded.excluded, exclusion_reason = excluded.exclusion_reason, last_seen = now();
      end loop;

      delete from ask_listings where product_id = any(k.ids) and last_seen < started;   -- listing ended or sold
      perform screen_ask_group(a.product_id, a.market, a.condition, a.grade)
        from (select distinct product_id, market, condition, grade from ask_listings where product_id = any(k.ids)) a;
      insert into ask_fetch_state (qkey, last_fetched, items, note)
      values (k.qkey, now(), jsonb_array_length(coalesce(body->'itemSummaries','[]'::jsonb)), 'ok')
      on conflict (qkey) do update set last_fetched = excluded.last_fetched, items = excluded.items, note = 'ok';
      done := done + 1;
    exception when others then
      insert into ask_fetch_state (qkey, last_fetched, note) values (k.qkey, now() - interval '6 days', left(sqlerrm, 150))
      on conflict (qkey) do update set last_fetched = excluded.last_fetched, note = excluded.note;
    end;
    perform pg_sleep(0.2);
  end loop;
  perform pg_advisory_unlock(515151);
  return done;
end $$;


ALTER FUNCTION "public"."fetch_ask_prices"("max_q" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_news"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare f record; body text; doc xml; n int := 0; k int;
begin
  perform http_setup();
  for f in select * from news_feeds where active loop
    begin
      body := (select content from extensions.http_get(f.url));
      doc := xmlparse(document body);
      insert into news_items (game_id, source, title, url, published_at)
      select f.game_id,
             coalesce(nullif((xpath('/item/source/text()', it))[1]::text, ''), f.source),
             left(regexp_replace(regexp_replace((xpath('/item/title/text()', it))[1]::text, '^\s*<!\[CDATA\[|\]\]>\s*$', '', 'g'), '\s+', ' ', 'g'), 300),
             (xpath('/item/link/text()', it))[1]::text,
             safe_ts((xpath('/item/pubDate/text()', it))[1]::text)
      from unnest(xpath('//item', doc)) it
      where (xpath('/item/link/text()', it))[1] is not null and (xpath('/item/title/text()', it))[1] is not null
      on conflict (url) do nothing;
      get diagnostics k = row_count; n := n + k;
      update news_feeds set last_ok = now(), last_error = null where url = f.url;
    exception when others then
      update news_feeds set last_error = left(sqlerrm, 200) where url = f.url;
    end;
  end loop;
  delete from news_items where coalesce(published_at, fetched_at) < now() - interval '60 days';
  return n;
end $_$;


ALTER FUNCTION "public"."fetch_news"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_bulba_checklist"("sid" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare s sets; page text; w text; n int := 0; cut int;
begin
  select * into s from sets where id = sid;
  page := bulba_page_for(s);
  select content::jsonb->'parse'->>'wikitext' into w from extensions.http_get(
    'https://bulbapedia.bulbagarden.net/w/api.php?action=parse&prop=wikitext&format=json&formatversion=2&redirects=1&page=' || extensions.urlencode(page));
  if w is null or w !~* 'setlist/[a-z]*entry' then
    insert into set_checklist_runs (set_id, page, n, note) values (sid, page, 0, 'no set list')
    on conflict (set_id) do update set page = excluded.page, checked_at = now(), n = 0, note = excluded.note;
    return 0;
  end if;
  -- merch-exclusive printings ("Additional Cards") are variants of numbered cards, not part of the checklist
  cut := coalesce(nullif(position(substring(w from '\n==\s*(?:Card|Set) lists?\s*==') in w), 0), 1); w := substr(w, cut);
  w := regexp_replace(w, 'title=Additional.*?Setlist/footer', '', 'gi');
  -- pages can also list other printings (e.g. the Japanese list); keep the entries printed "/N" with this set's main N
  insert into set_checklist (set_id, card_number, name)
  with e as (
    select split_part(m[1], '/', 1) num, split_part(m[1], '/', 2) den,
           bulba_entry_name(m[2]) nm
    from regexp_matches(w, '\{\{[Ss]etlist/[a-z]*entry\|([^|}\n]+)\|([^\n]*)', 'g') m),
  f as (select * from e where checklist_num_ok(s.code, num) and num ~ '\d'),
  md as (select f.den from f group by f.den
        order by count(distinct f.num) filter (where exists (select 1 from products p where p.set_id = sid and card_key(p.card_number) = card_key(f.num))) desc, count(distinct f.num) limit 1)  -- best overlap; on a tie the tighter list
  select distinct on (num) sid, num, nm from f
  where s.code = 'cel25cc' or den = (select den from md)
     or (s.language = 'EN' and den ~ '^[A-Z]+\d+$' and (select den from md) !~ '^[A-Z]')  -- prefixed sub-lists printed in the set (RC, H, SL, …)
  order by num
  on conflict (set_id, card_number) do update set name = excluded.name, seen_at = now();
  get diagnostics n = row_count;
  insert into set_checklist_runs (set_id, page, n, note) values (sid, page, n, null)
  on conflict (set_id) do update set page = excluded.page, checked_at = now(), n = excluded.n, note = null;
  return n;
end $_$;


ALTER FUNCTION "public"."fill_bulba_checklist"("sid" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_bulba_logos"("max_n" integer DEFAULT 60) RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare s record; u text; ok int := 0; n int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for s in select id, code, name, language from sets where game_id = 'pokemon' and logo_url is null and not coalesce(sync_note, '') like '%bulba_checked%'
           order by (language = 'JP') desc, release_date desc nulls last limit max_n loop
    n := n + 1; u := null;
    if s.language = 'JP' and s.code is not null then u := bulba_logo(s.code || '_'); end if;
    if u is null and s.language = 'EN' then u := bulba_logo(replace(regexp_replace(s.name, '[^A-Za-z0-9 &''-]', '', 'g'), ' ', '_') || '_'); end if;
    if u is not null then update sets set logo_url = u where id = s.id; ok := ok + 1;
    else update sets set sync_note = coalesce(sync_note, '') || ' bulba_checked' where id = s.id; end if;
  end loop;
  return json_build_object('checked', n, 'found', ok);
end $$;


ALTER FUNCTION "public"."fill_bulba_logos"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_bulba_logos_by_code"("max_n" integer DEFAULT 20) RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare s record; j jsonb; u text; ok int := 0; n int := 0; pre text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for s in select id, code, language from sets
           where game_id = 'pokemon' and logo_url is null and code is not null and coalesce(sync_note, '') not like '%bulba_code_checked%'
           order by release_date desc nulls last limit max_n loop
    n := n + 1; u := null;
    foreach pre in array array[s.code, upper(s.code)] loop
      exit when u is not null;
      begin
        j := (select content::jsonb from extensions.http_get('https://archives.bulbagarden.net/w/api.php?action=query&format=json&list=allimages&ailimit=50&aiprop=url&aiprefix=' || extensions.urlencode(pre || '_')));
        select x->>'url' into u from jsonb_array_elements(coalesce(j->'query'->'allimages', '[]'::jsonb)) x
         where lower(x->>'name') ~ ('^' || regexp_replace(lower(s.code), '([.+*?()\[\]{}|^$\\])', '\\\1', 'g') || '_logo(_jp|_en)?\.(png|jpg)$')
         order by case when lower(x->>'name') like '%\_logo\_' || (case when s.language = 'JP' then 'jp' else 'en' end) || '.%' then 0
                       when lower(x->>'name') ~ '_logo\.(png|jpg)$' then 1 else 2 end
         limit 1;
      exception when others then u := null; end;
    end loop;
    if u is not null then update sets set logo_url = u where id = s.id; ok := ok + 1;
    else update sets set sync_note = coalesce(sync_note, '') || ' bulba_code_checked' where id = s.id; end if;
  end loop;
  return json_build_object('checked', n, 'found', ok);
end $_$;


ALTER FUNCTION "public"."fill_bulba_logos_by_code"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_dbs_masters_pack_images"("max_n" integer DEFAULT 20) RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare idx text; s record; base text; pg text; html text; img text; ok int := 0; n int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  select content into idx from extensions.http_get('https://www.dbs-cardgame.com/us-en/product/');
  for s in select t.id, t.name from sets t
           where t.game_id = 'dragon-ball' and t.logo_url is null and coalesce(t.sync_note, '') not like '%masters_img_checked%'
             and exists (select 1 from set_links l where l.set_id = t.id and l.catalog_set like 'dragon-ball-super-masters-%')
           order by t.release_date desc nulls last limit max_n loop
    n := n + 1; pg := null; img := null;
    base := regexp_replace(s.name, '\s+(release event( cards)?|pre-release cards|\(2nd edition\))$', '', 'i');
    pg := case
      when base ~* '^Expansion Deck Box Set (\d+)' then 'dbs-es' || lpad((regexp_match(base, '(\d+)'))[1], 2, '0')
      when base ~* '^Draft Box (\d+)' then 'dbs-box' || lpad((regexp_match(base, '(\d+)'))[1], 2, '0')
      when base ~* 'Theme Selection: History of Son Goku' then 'dbs-ts01'
      when base ~* 'Theme Selection: History of Vegeta' then 'dbs-ts02'
      when base ~* '^Special Anniversary Set 2020$' then 'dbs-es13'
      when base ~* '^Special Anniversary Set 2021$' then 'dbs-es19'
      when base ~* '^Special Anniversary Set$' then 'dbs-es06'
      when base ~* '^5th Anniversary Set$' then 'dbs-es21'
    end;
    if pg is null and idx is not null then
      select p.page into pg from (
        select substring(t from '^([a-z0-9_-]+)\.php') page,
               regexp_replace(regexp_replace(lower(regexp_replace(split_part(substring(t from '>(.*)$'), '</a>', 1), '<[^>]+>|\[.*?\]|【.*?】|NEW', '', 'g')), '[^a-z0-9]', '', 'g'), '^the', '') nt
        from regexp_split_to_table(idx, '<a href="') t where t ~ '^dbs-(b\d+|tb\d+|mb\d+|eb\d+)\.php"') p
      where p.nt <> '' and p.nt = regexp_replace(regexp_replace(lower(base), '[^a-z0-9]', '', 'g'), '^the', '')
      limit 1;
    end if;
    if pg is not null then
      begin
        select content into html from extensions.http_get('https://www.dbs-cardgame.com/us-en/product/' || pg || '.php');
        img := (regexp_match(html, '(images/product/' || pg || '/[^"?'' ]+\.(png|jpg|webp))'))[1];
        if img is not null then img := 'https://www.dbs-cardgame.com/' || img; end if;
      exception when others then img := null; end;
    end if;
    if img is not null then update sets set logo_url = img where id = s.id; ok := ok + 1;
    else update sets set sync_note = coalesce(sync_note, '') || ' masters_img_checked' where id = s.id; end if;
  end loop;
  return json_build_object('checked', n, 'found', ok);
end $_$;


ALTER FUNCTION "public"."fill_dbs_masters_pack_images"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_dbs_official"("p_game" "text", "p_series" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $_$
declare c text; n int;
begin
  perform http_set_curlopt('CURLOPT_TIMEOUT','45');
  if p_game = 'fw' then
    select content into c from http_get('https://www.dbs-cardgame.com/fw/en/cardlist/?search=true&category%5B%5D=' || p_series);
    insert into dbs_official(game, series_id, card_id, base_id, name)
    select distinct on (m[1] || coalesce(m[2], '')) 'fw', p_series, m[1] || coalesce(m[2], ''), m[1], trim(m[3])
    from regexp_matches(c, 'detail\.php\?card_no=([A-Z0-9-]+)(?:&(?:amp;)?p=(_p\d+))?"[^>]*>\s*<img[^>]*alt="[A-Z0-9-]+ ([^"]*)"', 'g') m
    on conflict do nothing;
  else
    select content into c from http_get('https://www.dbs-cardgame.com/us-en/cardlist/?search=true&category=' || p_series);
    insert into dbs_official(game, series_id, card_id, base_id, name)
    select distinct on (m[1]) 'masters', p_series, m[1], regexp_replace(m[1], '_.*$', ''), trim(m[2])
    from regexp_matches(c, '<dt class="cardNumber">([^<]+)</dt>\s*<dd class="cardName">([^<]*)</dd>', 'g') m
    on conflict do nothing;
  end if;
  select count(*) into n from dbs_official where game = p_game and series_id = p_series;
  update dbs_official_series set loaded_at = now(), cards = n where game = p_game and series_id = p_series;
  return n;
end $_$;


ALTER FUNCTION "public"."fill_dbs_official"("p_game" "text", "p_series" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_dbs_pack_images"() RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare ok int := 0; npacks int;
  q constant text := chr(34);
  pat text;
begin
  pat := 'data' || '-src=' || q || '([^' || q || ']+)' || q || ' alt=' || q || '([^' || q || ']+)' || q;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  with pages as (
    select (select content from extensions.http_get('https://www.dbs-cardgame.com/fw/en/products/?page=' || g)) c from generate_series(1, 10) g),
  packs as (
    select upper((regexp_match(m[2], '\[([A-Za-z]{2}\d{2})\]'))[1]) code,
           regexp_replace(lower(regexp_replace(replace(m[2], chr(38) || 'amp;', chr(38)), '\[.*?\]|^(booster pack|starter deck( ex)?|story booster|manga booster)', '', 'gi')), '[^a-z0-9]', '', 'g') nname,
           case when m[1] ~ '^https?://' then m[1] else 'https://www.dbs-cardgame.com' || m[1] end img
    from pages, regexp_matches(coalesce(pages.c, ''), pat, 'g') m
    where m[2] ~ '\[[A-Za-z]{2}\d{2}\]'),
  s as (
    select t.id,
           upper(coalesce((regexp_match(t.code, '^([A-Za-z]{2}\d{2})'))[1], (regexp_match(t.name, '\[([A-Za-z]{2}\d{2})'))[1])) scode,
           regexp_replace(lower(regexp_replace(t.name, '\[.*?\]|\s+(release event cards|release event|pre-release cards|alternate art reprints)$|^starter deck( ex)?( \d+)?:?', '', 'gi')), '[^a-z0-9]', '', 'g') sname
    from sets t where t.game_id = 'dragon-ball' and t.logo_url is null),
  m as (
    select distinct on (s.id) s.id, p.img from s join packs p
      on (s.scode is not null and p.code = s.scode) or (s.scode is null and length(s.sname) >= 5 and p.nname = s.sname)
    order by s.id, (p.img ~* '_en\.') desc),
  u as (update sets t set logo_url = m.img from m where t.id = m.id returning 1)
  select (select count(*) from u), (select count(distinct code) from packs) into ok, npacks;
  return json_build_object('matched', ok, 'packs', npacks);
end $_$;


ALTER FUNCTION "public"."fill_dbs_pack_images"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_missing_from_checklist"("sid" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare s sets; r record; den text; img text; n int := 0;
begin
  select * into s from sets where id = sid;
  select split_part(card_number, '/', 2) into den from products
   where set_id = sid and card_number like '%/%' group by 1 order by count(*) desc limit 1;
  for r in select c.card_number, c.name from set_checklist_current c
           where c.set_id = sid and c.name is not null
             and not exists (select 1 from products p where p.set_id = sid and card_key(p.card_number) = card_key(c.card_number))
  loop
    img := limitless_jp_url(s.code, r.card_number);
    begin
      if (select status from extensions.http(('HEAD', img, null, null, null)::extensions.http_request)) <> 200 then img := null; end if;
    exception when others then img := null; end;
    insert into products (game_id, set_id, kind, name, card_number, variant, language, image_url, external_ids)
    values ('pokemon', sid, 'card', r.name,
            case when r.card_number ~ '^\d+$' then lpad(r.card_number, 3, '0') || coalesce('/' || den, '') else r.card_number end,
            '', s.language, img, jsonb_build_object('bulbapedia', bulba_page_for(s) || '#' || r.card_number))
    on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $_$;


ALTER FUNCTION "public"."fill_missing_from_checklist"("sid" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_onepiece_pack_images"("max_n" integer DEFAULT 30) RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare s record; pc text; dir text; u text; cand text; st int; ct text; ok int := 0; n int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
  for s in select id, code, name from sets
           where game_id = 'one-piece' and logo_url is null and coalesce(sync_note, '') not like '%pack_img_checked%'
           order by release_date desc nulls last limit max_n loop
    n := n + 1; u := null;
    pc := lower(replace(coalesce(
            (regexp_match(s.code, '^((?:OP|EB|PRB|ST|LT)-?\d+)', 'i'))[1],
            (regexp_match(s.name, '^(ST-\d+):', 'i'))[1],
            'st' || (regexp_match(s.name, '^Starter Deck (\d+):', 'i'))[1]), '-', ''));
    if pc ~ '^(op|eb|prb|st|lt)\d+$' then
      dir := case when pc ~ '^(st|lt)' then 'decks' else 'boosters' end;
      if pc ~ '^st\d$' then pc := 'st0' || substr(pc, 3); end if;
      foreach cand in array array['https://en.onepiece-cardgame.com/images/products/' || dir || '/' || pc || '/img_thumbnail.png',
                                  'https://www.onepiece-cardgame.com/images/products/' || dir || '/' || pc || '/img_thumbnail.png'] loop
        exit when u is not null;
        begin
          select status, (select value from unnest(headers) h where lower(h.field) = 'content-type') into st, ct from extensions.http_get(cand);
          if st = 200 and ct like 'image/%' then u := cand; end if;
        exception when others then null; end;
      end loop;
    end if;
    if u is not null then update sets set logo_url = u where id = s.id; ok := ok + 1;
    else update sets set sync_note = coalesce(sync_note, '') || ' pack_img_checked' where id = s.id; end if;
  end loop;
  return json_build_object('checked', n, 'found', ok);
end $_$;


ALTER FUNCTION "public"."fill_onepiece_pack_images"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_op_official"("p_series" "text") RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare c text; v_series text; n int;
begin
  select content into c from extensions.http_get('https://en.onepiece-cardgame.com/cardlist/?series=' || p_series);
  if c is null then return 0; end if;
  v_series := replace(regexp_replace((regexp_match(c, '<option value="' || p_series || '"[^>]*>([^<]+)</option>'))[1], '&lt;br[^&]*&gt;|&lt;[^&]*&gt;', ' ', 'g'), '&amp;', '&');
  insert into op_official (series_id, series_name, card_id, base_id, name)
  select p_series, btrim(regexp_replace(v_series, '\s+', ' ', 'g')), x.cid, regexp_replace(x.cid, '_[a-z]\d+$', ''), x.cname
  from (select substring(t.chunk from '^([^"]+)"') cid, substring(t.chunk from '<div class="cardName">([^<]*)</div>') cname
        from regexp_split_to_table(c, '<dl class="modalCol" id="') with ordinality t(chunk, i) where t.i > 1) x
  where x.cid is not null
  on conflict (series_id, card_id) do update set name = excluded.name, series_name = excluded.series_name;
  get diagnostics n = row_count;
  return n;
end $_$;


ALTER FUNCTION "public"."fill_op_official"("p_series" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_series_logos"() RETURNS integer
    LANGUAGE "sql"
    AS $$
  with u as (update series se set logo_url = (select s.logo_url from sets s where s.series_id = se.id and s.logo_url is not null and s.name !~* 'promo' order by s.release_date asc nulls last, s.id limit 1)
    where se.game_id = 'pokemon' and se.logo_url is null returning 1) select count(*)::int from u $$;


ALTER FUNCTION "public"."fill_series_logos"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_tcgdex_logos"("max_n" integer DEFAULT 20) RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare s record; base text; u text; st int; ct text; ok int := 0; n int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for s in select id, code, language from sets
           where game_id = 'pokemon' and logo_url is null and code is not null and coalesce(sync_note, '') not like '%logo_checked%'
           order by release_date desc nulls last limit max_n loop
    n := n + 1; u := null;
    begin
      select content::jsonb->>'logo' into base from extensions.http_get(
        'https://api.tcgdex.net/v2/' || case when s.language = 'JP' then 'ja' else 'en' end || '/sets/' || replace(s.code, '+', '%2B'));
      if base is not null then
        select status, (select value from unnest(headers) h where lower(h.field) = 'content-type') into st, ct from extensions.http_get(base || '.png');
        if st = 200 and ct like 'image/%' then u := base || '.png'; end if;
      end if;
    exception when others then null; end;
    if u is null and s.language = 'EN' then
      begin
        select status, (select value from unnest(headers) h where lower(h.field) = 'content-type') into st, ct from extensions.http_get('https://images.pokemontcg.io/' || lower(s.code) || '/logo.png');
        if st = 200 and ct like 'image/%' then u := 'https://images.pokemontcg.io/' || lower(s.code) || '/logo.png'; end if;
      exception when others then null; end;
    end if;
    if u is not null then update sets set logo_url = u where id = s.id; ok := ok + 1;
    else update sets set sync_note = coalesce(sync_note, '') || ' logo_checked' where id = s.id; end if;
  end loop;
  return json_build_object('checked', n, 'found', ok);
end $$;


ALTER FUNCTION "public"."fill_tcgdex_logos"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_tcgp_group"("p_group" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare cat int; pr jsonb; px jsonb; n int; t0 timestamptz := now();
begin
  select category_id into cat from tcgp_groups where group_id = p_group;
  perform http_set_curlopt('CURLOPT_TIMEOUT','45');
  select (content::jsonb)->'results' into pr from http_get('https://tcgcsv.com/tcgplayer/' || cat || '/' || p_group || '/products');
  select (content::jsonb)->'results' into px from http_get('https://tcgcsv.com/tcgplayer/' || cat || '/' || p_group || '/prices');
  if pr is null or px is null then
    update tcgp_groups set loaded_at = now(), printings = -1 where group_id = p_group;
    return -1;
  end if;
  insert into tcgp_printings(group_id, product_id, sub_type, name, number, rarity, image_url, market, seen_at)
  select p_group, (p->>'productId')::int, q->>'subTypeName', p->>'name',
         (select e->>'value' from jsonb_array_elements(p->'extendedData') e where e->>'name' = 'Number'),
         (select e->>'value' from jsonb_array_elements(p->'extendedData') e where e->>'name' = 'Rarity'),
         p->>'imageUrl', nullif(q->>'marketPrice','')::numeric, t0
  from jsonb_array_elements(pr) p
  join jsonb_array_elements(px) q on q->>'productId' = p->>'productId'
  where exists (select 1 from jsonb_array_elements(p->'extendedData') e where e->>'name' = 'Number')
  on conflict (group_id, product_id, sub_type) do update
    set name = excluded.name, number = excluded.number, rarity = excluded.rarity,
        image_url = excluded.image_url, market = excluded.market, seen_at = excluded.seen_at;
  select count(*) into n from tcgp_printings where group_id = p_group and seen_at = t0;
  update tcgp_groups set loaded_at = t0, printings = n where group_id = p_group;
  return n;
end $$;


ALTER FUNCTION "public"."fill_tcgp_group"("p_group" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_yugipedia_logos"("max_n" integer DEFAULT 50) RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare ids bigint[]; codes text[]; j jsonb; found int := 0; sfx text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '25000');
  select array_agg(id order by release_date desc nulls last), array_agg(code order by release_date desc nulls last) into ids, codes
  from (select id, code, release_date from sets
        where game_id = 'yugioh' and logo_url is null and code ~ '^[A-Za-z0-9]+$' and coalesce(sync_note, '') not like '%ygo_logo_checked%'
        order by release_date desc nulls last limit least(max_n, 50)) z;
  if ids is null then return json_build_object('checked', 0, 'found', 0); end if;
  foreach sfx in array array['-LogoEN.png', '-LogoNA.png'] loop
    j := (select content::jsonb from extensions.http_get('https://yugipedia.com/api.php?action=query&format=json&prop=imageinfo&iiprop=url&titles='
          || extensions.urlencode((select string_agg('File:' || c || sfx, '|') from unnest(codes) c))));
    with hit as (
      select substring(p.value->>'title' from '^File:([A-Za-z0-9]+)-') code, p.value->'imageinfo'->0->>'url' url
      from jsonb_each(coalesce(j->'query'->'pages', '{}'::jsonb)) p where p.value ? 'imageinfo')
    update sets s set logo_url = h.url from hit h
     where s.id = any(ids) and upper(s.code) = upper(h.code) and s.logo_url is null and h.url like 'https://%';
  end loop;
  select count(*) into found from sets where id = any(ids) and logo_url is not null;
  update sets set sync_note = coalesce(sync_note, '') || ' ygo_logo_checked' where id = any(ids) and logo_url is null;
  return json_build_object('checked', array_length(ids, 1), 'found', found);
end $_$;


ALTER FUNCTION "public"."fill_yugipedia_logos"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."friend_tradeables"("p_friend" "uuid") RETURNS json
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(json_agg(json_build_object('product_id', c.product_id, 'condition', c.condition, 'grade', c.grade, 'quantity', c.quantity,
           'price', case when c.show_price then c.asking_price end)), '[]'::json)
  from collection_items c
  where c.owner_id = p_friend and c.for_sale and is_connected(p_friend, auth.uid())
$$;


ALTER FUNCTION "public"."friend_tradeables"("p_friend" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_vendor_listing"("p_handle" "text") RETURNS json
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select json_build_object(
    'vendor', json_build_object('name', p.display_name, 'handle', p.handle, 'kind', p.kind),
    'items', coalesce((select json_agg(json_build_object(
        'product_id', pr.id, 'name', pr.name, 'set', s.name, 'number', pr.card_number, 'image', pr.image_url,
        'kind', pr.kind, 'language', pr.language, 'game', pr.game_id,
        'condition', c.condition, 'grade', c.grade, 'quantity', c.quantity,
        'price', case when c.show_price then c.asking_price end) order by pr.name)
      from collection_items c join products pr on pr.id = c.product_id left join sets s on s.id = pr.set_id
      where c.owner_id = p.id and c.for_sale), '[]'::json))
  from profiles p where lower(p.handle) = lower(p_handle) and p.vendor_page_on
$$;


ALTER FUNCTION "public"."get_vendor_listing"("p_handle" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grade_from_title"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select coalesce(upper(m[1]) || ' ' || m[2], '') from (select regexp_match(t, '\m(psa|bgs|cgc|sgc|beckett|ace)\s*(10|9\.5|9|8\.5|8|7)\M', 'i') m) x $$;


ALTER FUNCTION "public"."grade_from_title"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."http_setup"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
  select extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
  select extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '15000');
$$;


ALTER FUNCTION "public"."http_setup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."i_follow"("owner" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select owner = auth.uid() or exists (select 1 from follows where follower = auth.uid() and followee = owner and status = 'accepted')
$$;


ALTER FUNCTION "public"."i_follow"("owner" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."import_collection"("p_lines" "jsonb") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare l jsonb; added int := 0; merged int := 0; ex bigint;
begin
  for l in select * from jsonb_array_elements(p_lines) loop
    select id into ex from collection_items where owner_id = auth.uid() and product_id = (l->>'product_id')::bigint and condition = coalesce(l->>'condition','NM')
      and coalesce(grade,'') = coalesce(l->>'grade','') and coalesce(location,'') = coalesce(l->>'location','') and cost_paid is not distinct from (l->>'cost_paid')::numeric limit 1;
    if ex is not null then
      update collection_items set quantity = quantity + greatest(1, coalesce((l->>'quantity')::int, 1)) where id = ex; merged := merged + 1;
    else
      insert into collection_items (owner_id, product_id, condition, grade, quantity, cost_paid, location, notes, acquired_at, date_added)
      values (auth.uid(), (l->>'product_id')::bigint, coalesce(l->>'condition','NM'), coalesce(l->>'grade',''), greatest(1, coalesce((l->>'quantity')::int, 1)),
              (l->>'cost_paid')::numeric, nullif(l->>'location',''), nullif(l->>'notes',''), (l->>'acquired_at')::date, now());
      added := added + 1;
    end if;
  end loop;
  return json_build_object('added', added, 'merged', merged);
end $$;


ALTER FUNCTION "public"."import_collection"("p_lines" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."import_pair_items"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare r record; pick bigint; n int := 0; taken bigint[] := '{}';
begin
  update import_plan set item_id = null, current_product = null;
  for r in
    select e.*, card_key(e.card_number) ck,
      (select count(*) from collection_items c join products p on p.id=c.product_id
        where p.game_id=e.game_id and card_key(p.card_number)=card_key(e.card_number) and c.date_added is not distinct from e.d
          and c.condition is not distinct from e.condition and c.quantity=e.quantity) ncand
    from import_plan e order by 18, e.rn  -- rarest first
  loop
    select c.id into pick from collection_items c join products p on p.id=c.product_id
     where p.game_id=r.game_id and card_key(p.card_number)=r.ck and c.date_added is not distinct from r.d
       and c.condition is not distinct from r.condition and c.quantity=r.quantity and not (c.id = any(taken))
     order by (p.set_id = r.target_set) desc,
              (p.variant = r.variant) desc,
              (lower(p.name) = lower(r.product_name)) desc,
              (p.name ilike '%' || coalesce(substring(r.product_name from '\(([^)]*)\)\s*$'), '§') || '%') desc,
              c.id
     limit 1;
    if pick is not null then
      taken := taken || pick;
      update import_plan set item_id = pick, current_product = (select product_id from collection_items where id = pick) where rn = r.rn;
      n := n + 1;
    end if;
  end loop;
  return n;
end $_$;


ALTER FUNCTION "public"."import_pair_items"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_connected"("a" "uuid", "b" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from follows where status = 'accepted' and ((follower = a and followee = b) or (follower = b and followee = a)))
$$;


ALTER FUNCTION "public"."is_connected"("a" "uuid", "b" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."jp_card_name_en"("jp" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare
  t text := btrim(jp); suffix text := ''; prefix text := ''; core text; en text; m text[];
  owners jsonb := '{"ヒビキ":"Ethan''s","ロケット団":"Team Rocket''s","N":"N''s","リーリエ":"Lillie''s","ホップ":"Hop''s","マリィ":"Marnie''s","シロナ":"Cynthia''s","スティーブン":"Steven''s","アイリス":"Iris''s","ナンジャモ":"Iono''s","カスミ":"Misty''s","タケシ":"Brock''s","エリカ":"Erika''s","ナツメ":"Sabrina''s","カツラ":"Blaine''s","キョウ":"Koga''s","マチス":"Lt. Surge''s","サカキ":"Giovanni''s"}';
  regions jsonb := '{"アローラ":"Alolan","ガラル":"Galarian","ヒスイ":"Hisuian","パルデア":"Paldean"}';
  energy jsonb := '{"草":"Grass","炎":"Fire","水":"Water","雷":"Lightning","超":"Psychic","闘":"Fighting","悪":"Darkness","鋼":"Metal","フェアリー":"Fairy"}';
begin
  if t is null or t !~ '[ぁ-んァ-ヶ一-龯]' then return null; end if;
  -- basic energy
  m := regexp_match(t, '^基本(.+)エネルギー$');
  if m is not null and energy ? m[1] then return 'Basic ' || (energy->>m[1]) || ' Energy'; end if;
  -- latin suffix (ex, EX, GX, V, VMAX, VSTAR, BREAK, LV.X)
  m := regexp_match(t, '^(.*?)\s*(ex|EX|GX|VMAX|VSTAR|V|BREAK|LV\.X)$');
  if m is not null then t := m[1]; suffix := ' ' || m[2]; end if;
  -- owner possessive
  m := regexp_match(t, '^(.+?)の(.+)$');
  if m is not null then
    if owners ? m[1] then prefix := (owners->>m[1]) || ' '; t := m[2]; else return null; end if;
  end if;
  -- radiant / region
  if t like 'かがやく%' then prefix := prefix || 'Radiant '; t := substr(t, 5); end if;
  m := regexp_match(t, '^(アローラ|ガラル|ヒスイ|パルデア)(.+)$');
  if m is not null and not exists (select 1 from pokemon_species_names where name_ja = t) then
    prefix := prefix || (regions->>m[1]) || ' '; t := m[2];
  end if;
  -- species, or Mega + species
  select name_en into en from pokemon_species_names where name_ja = t;
  if en is null and t like 'メガ%' then
    select 'Mega ' || name_en into en from pokemon_species_names where name_ja = substr(t, 3);
  end if;
  if en is null then return null; end if;
  return prefix || en || suffix;
end $_$;


ALTER FUNCTION "public"."jp_card_name_en"("jp" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."jp_card_name_en2"("jp" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare t text := btrim(jp); m text[]; d text := ''; r text;
begin
  r := jp_card_name_en(t); if r is not null then return r; end if;
  if t like '%（デルタ種）' then t := btrim(replace(t, '（デルタ種）', '')); d := ' δ'; end if;
  -- already-English core, e.g. "Latias ex（デルタ種）", "BugsyのBeedrill"
  m := regexp_match(t, '^([A-Za-z][A-Za-z .''-]*)の([A-Za-z][A-Za-z .''-]*)$');
  if m is not null then return initcap(m[1]) || '''s ' || initcap(m[2]) || d; end if;
  if t ~ '^[A-Za-z][A-Za-z .''-]*$' then
    return regexp_replace(initcap(t), ' (Ex|Gx)$', ' ' || lower(right(t,2))) || d;
  end if;
  if d <> '' then r := jp_card_name_en(t); if r is not null then return r || d; end if; end if;
  return null;
end $_$;


ALTER FUNCTION "public"."jp_card_name_en2"("jp" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."jp_norm"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select regexp_replace(regexp_replace(coalesce(t,''), '\(JP\)', '', 'gi'), '[\s　・•:：「」『』〜~\-－()（）&＆]', '', 'g') $$;


ALTER FUNCTION "public"."jp_norm"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."limitless_jp_url"("p_code" "text", "p_num" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select 'https://limitlesstcg.nyc3.digitaloceanspaces.com/tpc/' || p_code || '/' || p_code || '_' || nullif(ltrim(regexp_replace(split_part(p_num, '/', 1), '[^0-9]', '', 'g'), '0'), '') || '_R_JP_LG.png' $$;


ALTER FUNCTION "public"."limitless_jp_url"("p_code" "text", "p_num" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_dbs_official_series"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare c text; n int := 0;
begin
  perform http_set_curlopt('CURLOPT_TIMEOUT','30');
  select content into c from http_get('https://www.dbs-cardgame.com/fw/en/cardlist/');
  insert into dbs_official_series(game, series_id, series_name)
  select 'fw', m[1], trim(m[2]) from regexp_matches(c, 'data-val="(\d{6})"[^>]*>([^<]+)</a>', 'g') m
  on conflict (game, series_id) do update set series_name = excluded.series_name;
  select content into c from http_get('https://www.dbs-cardgame.com/us-en/cardlist/');
  insert into dbs_official_series(game, series_id, series_name)
  select distinct on (m[1]) 'masters', m[1], trim(m[2]) from regexp_matches(c, '<option value="(\d{6})"\s*>([^<]+)</option>', 'g') m
  on conflict (game, series_id) do update set series_name = excluded.series_name;
  select count(*) into n from dbs_official_series;
  return n;
end $$;


ALTER FUNCTION "public"."list_dbs_official_series"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_tcgp_groups"("p_category" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare n int;
begin
  perform http_set_curlopt('CURLOPT_TIMEOUT','30');
  insert into tcgp_groups(category_id, group_id, name, abbreviation, published)
  select p_category, (g->>'groupId')::int, g->>'name', g->>'abbreviation', (g->>'publishedOn')::date
  from http_get('https://tcgcsv.com/tcgplayer/' || p_category || '/groups') h, jsonb_array_elements((h.content::jsonb)->'results') g
  on conflict (group_id) do update set name = excluded.name, abbreviation = excluded.abbreviation, published = excluded.published;
  get diagnostics n = row_count;
  return n;
end $$;


ALTER FUNCTION "public"."list_tcgp_groups"("p_category" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listings_check"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare have int;
begin
  select coalesce(sum(quantity),0) into have from collection_items
  where owner_id = new.owner_id and product_id = new.product_id and condition = new.condition and grade = new.grade;
  if new.status = 'active' and new.quantity > have then raise exception 'You only own % of this item in that condition', have; end if;
  return new;
end $$;


ALTER FUNCTION "public"."listings_check"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_import"("p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare r jsonb; out jsonb := '[]'::jsonb; nm text; sn text; nk int; g text; lg text; kd text; best jsonb;
begin
  perform set_limit(0.28);
  for r in select * from jsonb_array_elements(p_rows) loop
    nm := lower(trim(coalesce(r->>'name',''))); sn := lower(trim(coalesce(r->>'set',''))); nk := num_key(r->>'number');
    g := nullif(r->>'game',''); lg := nullif(r->>'lang',''); kd := nullif(r->>'kind','');
    with c as (
      select p.id from products p where nm <> '' and lower(p.name) % nm and (g is null or p.game_id = g)
      union
      select p.id from products p where nk is not null and num_key(p.card_number) = nk and (g is null or p.game_id = g)
    ), sc as (
      select p.id, p.name, p.card_number, p.language, p.kind, p.game_id, s.name set_name,
        (0.5 * similarity(lower(p.name), nm)
         + case when sn <> '' then 0.3 * greatest(similarity(lower(coalesce(s.name,'')), sn), similarity(lower(coalesce(s.name_jp,'')), sn), case when lower(coalesce(s.code,'')) = sn then 1 else 0 end) else 0.1 end
         + case when nk is not null and num_key(p.card_number) = nk then 0.3 when nk is not null then -0.15 else 0 end
         + case when lg is not null and p.language = lg then 0.05 when lg is not null then -0.1 else 0 end
         + case when kd is not null and p.kind = kd then 0.03 else 0 end)::numeric(6,3) score
      from c join products p on p.id = c.id left join sets s on s.id = p.set_id
    )
    select coalesce(jsonb_agg(to_jsonb(x) order by x.score desc), '[]'::jsonb) into best from (select * from sc order by score desc limit 4) x;
    out := out || jsonb_build_array(best);
  end loop;
  return out;
end $$;


ALTER FUNCTION "public"."match_import"("p_rows" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_product"("src" bigint, "tgt" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into _merged_products (id, game_id, set_id, kind, name, card_number, rarity, variant, language, image_url, external_ids, price_tier, created_at, special, name_jp, merged_into, merged_at)
  select p.id, p.game_id, p.set_id, p.kind, p.name, p.card_number, p.rarity, p.variant, p.language, p.image_url, p.external_ids, p.price_tier, p.created_at, p.special, p.name_jp, tgt, now()
  from products p where p.id = src;
  update collection_items set product_id = tgt where product_id = src;
  update cart_items c set product_id = tgt where product_id = src and not exists (select 1 from cart_items x where x.cart_id = c.cart_id and x.product_id = tgt and x.side = c.side and x.condition = c.condition and x.grade = c.grade);
  delete from cart_items where product_id = src;
  update wants w set product_id = tgt where product_id = src and not exists (select 1 from wants x where x.owner_id = w.owner_id and x.product_id = tgt and x.condition = w.condition);
  delete from wants where product_id = src;
  update listings set product_id = tgt where product_id = src;
  update trade_ledger set product_id = tgt where product_id = src;
  update price_alerts set product_id = tgt where product_id = src;
  update alert_events set product_id = tgt where product_id = src;
  update sold_listings set product_id = tgt where product_id = src;
  update scan_log set chosen_catalog_id = tgt where chosen_catalog_id = src;
  delete from products where id = src;
end $$;


ALTER FUNCTION "public"."merge_product"("src" bigint, "tgt" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."move_items"("p_from" "uuid", "p_to" "uuid", "p_items" "jsonb", "p_ref" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare it jsonb; pid bigint; c text; g text; q int; r record; left_q int; cost numeric;
begin
  for it in select * from jsonb_array_elements(p_items) loop
    pid := (it->>'product_id')::bigint; c := it->>'condition'; g := coalesce(it->>'grade',''); q := (it->>'quantity')::int; left_q := q;
    cost := avg_cost(p_from, pid, c, g);
    for r in select id, quantity from collection_items where owner_id = p_from and product_id = pid and condition = c and grade = g order by id loop
      exit when left_q = 0;
      if r.quantity <= left_q then delete from collection_items where id = r.id; left_q := left_q - r.quantity;
      else update collection_items set quantity = quantity - left_q where id = r.id; left_q := 0; end if;
    end loop;
    select id into r from collection_items where owner_id = p_to and product_id = pid and condition = c and grade = g order by id limit 1;
    if found then update collection_items set quantity = quantity + q where id = r.id;
    else insert into collection_items (owner_id, product_id, condition, grade, quantity, date_added, acquired_at) values (p_to, pid, c, g, q, current_date, current_date); end if;
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, unit_cost, source, ref_id) values (p_from, pid, c, g, 'out', q, cost, 'swap', p_ref);
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, source, ref_id) values (p_to, pid, c, g, 'in', q, 'swap', p_ref);
  end loop;
end $$;


ALTER FUNCTION "public"."move_items"("p_from" "uuid", "p_to" "uuid", "p_items" "jsonb", "p_ref" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mtg_finish"("f" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case f when 'nonfoil' then 'Normal' when 'foil' then 'Foil' when 'etched' then 'Etched Foil' else initcap(f) end $$;


ALTER FUNCTION "public"."mtg_finish"("f" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."norm"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select trim(regexp_replace(lower(coalesce(t,'')), '[^a-z0-9]+', ' ', 'g')) $$;


ALTER FUNCTION "public"."norm"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."num_key"("t" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$ select nullif(substring(regexp_replace(split_part(coalesce(t,''), '/', 1), '^.*-', '') from '[0-9]+'), '')::int $$;


ALTER FUNCTION "public"."num_key"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."offer_action"("p_offer" bigint, "p_action" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare o record; l record; me uuid := auth.uid(); left_qty int;
begin
  select * into o from offers where id = p_offer for update;
  if not found then raise exception 'Offer not found'; end if;
  select * into l from listings where id = o.listing_id for update;
  if p_action = 'accept' and me = o.seller_id and o.status = 'pending' then
    if o.quantity > l.quantity then raise exception 'Only % left on this listing', l.quantity; end if;
    update offers set status = 'accepted', updated_at = now() where id = p_offer;
  elsif p_action = 'decline' and me = o.seller_id and o.status in ('pending','accepted') then
    update offers set status = 'declined', updated_at = now() where id = p_offer;
  elsif p_action = 'withdraw' and me = o.buyer_id and o.status in ('pending','accepted') then
    update offers set status = 'withdrawn', updated_at = now() where id = p_offer;
  elsif p_action = 'sent' and me = o.seller_id and o.status = 'accepted' then
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, unit_price, unit_cost, source, ref_id)
    values (me, l.product_id, l.condition, l.grade, 'out', o.quantity, o.price, avg_cost(me, l.product_id, l.condition, l.grade), 'offer', o.id);
    perform adjust_collection(l.product_id, l.condition, l.grade, -o.quantity);
    left_qty := l.quantity - o.quantity;
    update listings set quantity = greatest(left_qty, 1), status = case when left_qty <= 0 then 'sold' else status end where id = l.id;
    update offers set status = 'sent', updated_at = now() where id = p_offer;
  elsif p_action = 'received' and me = o.buyer_id and o.status = 'sent' then
    perform adjust_collection(l.product_id, l.condition, l.grade, o.quantity);
    perform blend_cost(me, l.product_id, l.condition, l.grade, o.quantity, o.price);
    insert into trade_ledger (owner_id, product_id, condition, grade, direction, quantity, unit_price, source, ref_id)
    values (me, l.product_id, l.condition, l.grade, 'in', o.quantity, o.price, 'offer', o.id);
    update offers set status = 'received', updated_at = now() where id = p_offer;
  else
    raise exception 'That action isn''t available for this offer';
  end if;
  return (select status from offers where id = p_offer);
end $$;


ALTER FUNCTION "public"."offer_action"("p_offer" bigint, "p_action" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."offers_before_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare l record;
begin
  select * into l from listings where id = new.listing_id;
  if not found or l.status <> 'active' then raise exception 'This listing is no longer available'; end if;
  if l.owner_id = new.buyer_id then raise exception 'You can''t make an offer on your own listing'; end if;
  if not exists (select 1 from follows where follower = new.buyer_id and followee = l.owner_id and status = 'accepted') then
    raise exception 'Follow this seller first'; end if;
  if new.quantity > l.quantity then raise exception 'Only % available', l.quantity; end if;
  new.seller_id := l.owner_id; new.status := 'pending'; new.created_at := now(); new.updated_at := now();
  return new;
end $$;


ALTER FUNCTION "public"."offers_before_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."op_norm"("n" "text", "num" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
 select trim(regexp_replace(lower(replace(replace(replace(replace(coalesce(n,''), '(' || coalesce(num,'') || ')', ''), '- ' || coalesce(num,''), ''), '(' || right(coalesce(num,''), 3) || ')', ''), ' - ' || right(coalesce(num,''),3), '')), '\((sec|sr|r|uc|c|l|sp)\)|\s+', ' ', 'g')) $$;


ALTER FUNCTION "public"."op_norm"("n" "text", "num" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."op_official_logos"("p_batch" integer DEFAULT 8) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare k text; p text; res record; lg text; n int := 0; found int := 0;
begin
  for k in
    select distinct lower(replace(split_part(s.code, ' ', 1), '-', '')) kk
    from sets s
    where s.game_id = 'one-piece' and not s.hidden and s.logo_url is null and s.code ~* '^(OP|EB|PRB|ST)-?[0-9]+'
      and not exists (select 1 from op_logo o where o.code = lower(replace(split_part(s.code, ' ', 1), '-', '')) and (o.logo is not null or o.probed_at > now() - interval '7 days'))
    order by 1 limit p_batch
  loop
    n := n + 1; lg := null;
    foreach p in array array['products/' || k || '.html', 'products/decks/' || k || '.html'] loop
      begin select status, content into res from extensions.http_get('https://en.onepiece-cardgame.com/' || p); exception when others then res := null; end;
      if res.status = 200 then lg := substring(res.content from '(?:src|data-src)="([^"]*/logo(?:_product)?\.(?:webp|png))"'); exit when lg is not null; end if;
    end loop;
    if lg is not null and lg !~ '^https?:' then lg := 'https://en.onepiece-cardgame.com' || lg; end if;
    insert into op_logo(code, page, logo) values (k, case when lg is not null then p end, lg)
      on conflict (code) do update set page = excluded.page, logo = coalesce(excluded.logo, op_logo.logo), probed_at = now();
    if lg is not null then
      update sets set logo_url = lg where game_id = 'one-piece' and logo_url is null and lower(replace(split_part(code, ' ', 1), '-', '')) = k;
      found := found + 1;
    end if;
  end loop;
  return json_build_object('checked', n, 'found', found);
end $$;


ALTER FUNCTION "public"."op_official_logos"("p_batch" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."op_tag"("n" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
 select case when n ~* '(pirate flag|jolly roger)' then 'JR'
             when n ~* 'manga' then 'MANGA'
             when n ~* 'treasure' then 'TR'
             when n ~* 'reprint' then 'REPRINT'
             when n ~* '\((parallel|alternate art|full art|alt art)\)' then 'AA'
             when n ~* '\((sp|special)' then 'SP'
             else 'BASE' end $$;


ALTER FUNCTION "public"."op_tag"("n" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."op_variant"("n" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when n ~* '\((alternate art|alt art)\)' then 'Alternate Art'
    when n ~* '\(parallel\)' then 'Parallel'
    when n ~* '\(manga\)' then 'Manga'
    when n ~* '\(sp\)' then 'SP'
    when n ~* '\(full art\)' then 'Full Art'
    when n ~* '\(foil\)' then 'Foil'
    else 'Normal' end $$;


ALTER FUNCTION "public"."op_variant"("n" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pcom_image_url"("p_tcgdex_url" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  with m as (select regexp_match(p_tcgdex_url, '^https://assets\.tcgdex\.net/en/[^/]+/([^/]+)/([^/]+)/') x),
  s as (select case when x[1] like '%.5%' then upper(regexp_replace(regexp_replace(x[1], '([a-z]+)0*(\d)', '\1\2'), '\.5', 'pt5')) else upper(x[1]) end code,
               regexp_replace(x[2], '^0+(\d)', '\1') num from m where x is not null)
  select 'https://assets.pokemon.com/static-assets/content-assets/cms2/img/cards/web/' || code || '/' || code || '_EN_' || num || '.png' from s
$$;


ALTER FUNCTION "public"."pcom_image_url"("p_tcgdex_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pcom_slug_candidates"("s" "public"."sets") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select array_remove(array[
    case s.code when 'sv01' then 'scarlet-violet' when 'sv03.5' then '151' when 'swsh1' then 'sword-shield' when 'me01' then 'mega-evolution' end,
    trim(both '-' from regexp_replace(lower(replace(replace(s.name, 'é', 'e'), '&', 'and')), '[^a-z0-9]+', '-', 'g')),
    trim(both '-' from regexp_replace(lower(replace(s.name, 'é', 'e')), '[^a-z0-9]+', '-', 'g'))], null) $$;


ALTER FUNCTION "public"."pcom_slug_candidates"("s" "public"."sets") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."phase1_selftest"() RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare res json; uid uuid := gen_random_uuid(); p1 bigint; p2 bigint; p3 bigint; listing json; anon_items int; anon_profiles int; anon_fn_off json;
begin
  select id into p1 from products order by id limit 1;
  select id into p2 from products order by id offset 1 limit 1;
  select id into p3 from products order by id offset 2 limit 1;
  begin
    insert into auth.users (id, email, aud, role) values (uid, 'phase1-selftest@example.invalid', 'authenticated', 'authenticated');
    insert into profiles (id, handle, display_name, vendor_page_on) values (uid, 'selftest_vendor', 'Self Test', true);
    insert into collection_items (owner_id, product_id, condition, grade, quantity, for_sale, asking_price, show_price) values
      (uid, p1, 'NM', '', 1, true, 25.00, true),
      (uid, p2, 'NM', '', 2, true, 40.00, false),
      (uid, p3, 'NM', '', 3, false, 99.00, true);
    perform set_config('role', 'anon', true);
    listing := get_vendor_listing('selftest_vendor');
    select count(*) into anon_items from collection_items;
    select count(*) into anon_profiles from profiles;
    perform set_config('role', 'postgres', true);
    update profiles set vendor_page_on = false where id = uid;
    perform set_config('role', 'anon', true);
    anon_fn_off := get_vendor_listing('selftest_vendor');
    perform set_config('role', 'postgres', true);
    res := json_build_object(
      'items_returned', json_array_length(listing->'items'),
      'not_for_sale_leaked', exists (select 1 from json_array_elements(listing->'items') e where (e->>'product_id')::bigint = p3),
      'hidden_price_is_null', (select (e->>'price') is null from json_array_elements(listing->'items') e where (e->>'product_id')::bigint = p2),
      'shown_price', (select e->>'price' from json_array_elements(listing->'items') e where (e->>'product_id')::bigint = p1),
      'anon_rows_collection', anon_items, 'anon_rows_profiles', anon_profiles,
      'page_off_returns', coalesce(anon_fn_off::text, 'nothing'));
    raise exception 'rollback-selftest';
  exception when others then
    if sqlerrm <> 'rollback-selftest' then res := json_build_object('error', sqlerrm); end if;
  end;
  return res;
end $$;


ALTER FUNCTION "public"."phase1_selftest"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."phase3_selftest"() RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare res json; a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); p1 bigint; p2 bigint; tid bigint; seen json;
  a_has_p1 int; a_has_p2 int; b_has_p1 int; b_has_p2 int; st1 text; st2 text; st3 text; st4 text; ledger int; stranger_blocked boolean := false;
begin
  select id into p1 from products where kind = 'card' order by id limit 1;
  select id into p2 from products where kind = 'card' order by id offset 1 limit 1;
  begin
    insert into auth.users (id, email, aud, role) values (a, 'p3-a@example.invalid', 'authenticated', 'authenticated'), (b, 'p3-b@example.invalid', 'authenticated', 'authenticated');
    insert into profiles (id, handle, display_name) values (a, 'p3_test_a', 'Test A'), (b, 'p3_test_b', 'Test B');
    insert into follows (follower, followee, status) values (a, b, 'accepted');
    insert into collection_items (owner_id, product_id, condition, grade, quantity, for_sale) values (a, p1, 'NM', '', 1, true), (b, p2, 'NM', '', 2, true);
    perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    seen := friend_tradeables(b);
    insert into trade_proposals (from_user, to_user, offered_items, requested_items)
      values (a, b, json_build_array(json_build_object('product_id', p1, 'condition', 'NM', 'grade', '', 'quantity', 1))::jsonb,
                    json_build_array(json_build_object('product_id', p2, 'condition', 'NM', 'grade', '', 'quantity', 1))::jsonb) returning id into tid;
    st1 := 'proposed';
    perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
    st2 := trade_action(tid, 'accept');
    st3 := trade_action(tid, 'done');
    perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
    st4 := trade_action(tid, 'done');
    perform set_config('role', 'postgres', true);
    select coalesce(sum(quantity),0) into a_has_p1 from collection_items where owner_id = a and product_id = p1;
    select coalesce(sum(quantity),0) into a_has_p2 from collection_items where owner_id = a and product_id = p2;
    select coalesce(sum(quantity),0) into b_has_p1 from collection_items where owner_id = b and product_id = p1;
    select coalesce(sum(quantity),0) into b_has_p2 from collection_items where owner_id = b and product_id = p2;
    select count(*) into ledger from trade_ledger where ref_id = tid and source = 'swap';
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    stranger_blocked := json_array_length(friend_tradeables(b)) = 0;
    perform set_config('role', 'postgres', true);
    res := json_build_object('friend_sees_items', json_array_length(seen), 'statuses', st1 || ' > ' || st2 || ' > ' || st3 || ' > ' || st4,
      'A_after', json_build_object('gave_p1_left', a_has_p1, 'received_p2', a_has_p2),
      'B_after', json_build_object('received_p1', b_has_p1, 'p2_left', b_has_p2),
      'ledger_rows', ledger, 'stranger_blocked', stranger_blocked);
    raise exception 'rollback-selftest';
  exception when others then
    if sqlerrm <> 'rollback-selftest' then res := json_build_object('error', sqlerrm); end if;
  end;
  return res;
end $$;


ALTER FUNCTION "public"."phase3_selftest"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."price_as_of"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_kind" "text", "p_day" "date") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  select percentile_cont(0.5) within group (order by price)::numeric(12,2)
  from (select price from sold_listings
        where product_id = p_product and market = 'AU'
          and ((condition = p_condition and grade = coalesce(p_grade,'')) or (p_kind = 'sealed' and condition = 'Sealed'))
          and sold_is_credible(excluded, user_decision)
          and sold_at < p_day + 1 and sold_at >= p_day - 90
        order by sold_at desc limit 10) x
$$;


ALTER FUNCTION "public"."price_as_of"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_kind" "text", "p_day" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."probe_limitless_jp"("p_batch" integer DEFAULT 40) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare r record; res record; ok int := 0; tried int := 0;
begin
  for r in
    select p.id, limitless_jp_url(s.code, p.card_number) u
    from products p join sets s on s.id = p.set_id
    where p.game_id = 'pokemon' and p.language = 'JP' and p.kind = 'card' and p.image_url is null
      and s.code is not null and p.card_number ~ '[0-9]'
      and not exists (select 1 from img_probe i where i.product_id = p.id)
    order by exists (select 1 from collection_items c where c.product_id = p.id) desc, p.id
    limit p_batch
  loop
    tried := tried + 1;
    begin
      select status, (select value from unnest(headers) h where lower(h.field) = 'content-type') ct into res from extensions.http_get(r.u);
    exception when others then res := null; end;
    insert into img_probe(product_id, url, status) values (r.id, r.u, coalesce(res.status, 0)) on conflict (product_id) do update set status = excluded.status, probed_at = now();
    if res.status = 200 and res.ct like 'image/%' then update products set image_url = r.u where id = r.id; ok := ok + 1; end if;
  end loop;
  return json_build_object('tried', tried, 'found', ok);
end $$;


ALTER FUNCTION "public"."probe_limitless_jp"("p_batch" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."probe_pcom_expansion"("sid" bigint) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare s sets; sl text; st int; c text; m text[];
begin
  select * into s from sets where id = sid;
  foreach sl in array pcom_slug_candidates(s) loop
    begin
      select status, content into st, c from extensions.http_get('https://tcg.pokemon.com/en-us/expansions/' || sl || '/');
    exception when others then st := 0; end;
    if st = 200 then
      m := regexp_match(c, 'dz3we2x72f7ol\.cloudfront\.net/expansions/([^/]+)/en-us/([A-Za-z0-9]+)_EN_\d+');
      if m is not null then
        insert into pcom_expansions (set_id, page_slug, img_slug, code) values (sid, sl, m[1], m[2])
        on conflict (set_id) do update set page_slug = excluded.page_slug, img_slug = excluded.img_slug, code = excluded.code, checked_at = now(), note = null;
        return sl || ' -> ' || m[1] || '/' || m[2];
      end if;
    end if;
  end loop;
  insert into pcom_expansions (set_id, note) values (sid, 'no page') on conflict (set_id) do update set checked_at = now(), note = 'no page';
  return null;
end $$;


ALTER FUNCTION "public"."probe_pcom_expansion"("sid" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."probe_ptcg_alt"("p_batch" integer DEFAULT 40) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare r record; u text; v text; st int; ok int := 0; n int := 0;
begin
  for r in select p.id, a.ptcg_id, split_part(p.card_number, '/', 1) num from products p join sets s on s.id = p.set_id join ptcg_alt a on a.set_code = s.code
    where p.kind = 'card' and p.language = 'EN' and (p.image_url is null or (p.image_url not ilike '%pokemontcg.io%' and p.image_url not like 'https://dz3we2x72f7ol.cloudfront.net/%'))
      and not exists (select 1 from img_probe_ptcg i where i.product_id = p.id)
    order by exists (select 1 from collection_items c where c.product_id = p.id) desc, p.id limit p_batch
  loop
    n := n + 1; st := 0; u := null;
    foreach v in array array[regexp_replace(r.num, '^0+(?=[0-9])', ''), r.num] loop
      begin select status into st from extensions.http_get('https://images.pokemontcg.io/' || r.ptcg_id || '/' || v || '_hires.png'); exception when others then st := 0; end;
      if st = 200 then u := 'https://images.pokemontcg.io/' || r.ptcg_id || '/' || v || '_hires.png'; exit; end if;
    end loop;
    insert into img_probe_ptcg(product_id, url, status) values (r.id, u, st) on conflict (product_id) do update set url = excluded.url, status = excluded.status, probed_at = now();
    if u is not null then update products set image_url = u where id = r.id; ok := ok + 1; end if;
  end loop;
  return json_build_object('tried', n, 'found', ok);
end $$;


ALTER FUNCTION "public"."probe_ptcg_alt"("p_batch" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."product_in_use"("p" bigint) RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select exists (select 1 from collection_items where product_id = p) or exists (select 1 from cart_items where product_id = p)
      or exists (select 1 from listings where product_id = p) or exists (select 1 from trade_ledger where product_id = p)
      or exists (select 1 from wants where product_id = p) or exists (select 1 from price_alerts where product_id = p) $$;


ALTER FUNCTION "public"."product_in_use"("p" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."products_special"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.special := classify_special((select name from sets where id = new.set_id), new.name, new.variant, new.rarity);
  return new;
end $$;


ALTER FUNCTION "public"."products_special"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_stats"("p_ids" "uuid"[]) RETURNS TABLE("id" "uuid", "trades" bigint, "rating" numeric, "ratings" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select u.id,
         (select count(*) from offers o where o.status = 'received' and (o.buyer_id = u.id or o.seller_id = u.id)),
         (select round(avg(stars)::numeric, 1) from trade_ratings r where r.ratee_id = u.id),
         (select count(*) from trade_ratings r where r.ratee_id = u.id)
  from unnest(p_ids) as u(id)
$$;


ALTER FUNCTION "public"."profile_stats"("p_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ptcg_image_url"("p_tcgdex_url" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  with m as (select regexp_match(p_tcgdex_url, '^https://assets\.tcgdex\.net/en/[^/]+/([^/]+)/([^/]+)/') x),
  s as (select regexp_replace(x[2], '^0+(?=\d)', '') num, case
      when x[1] = 'sv10.5b' then 'zsv10pt5' when x[1] = 'sv10.5w' then 'rsv10pt5' when x[1] = 'swsh12.5' then 'swsh12pt5'
      when x[1] ~ '^(swsh|sm)' and x[1] like '%.5' then regexp_replace(x[1], '\.5$', '5')
      else regexp_replace(regexp_replace(x[1], '([a-z]+)0*(\d)', '\1\2'), '\.5$', 'pt5') end setc from m where x is not null)
  select 'https://images.pokemontcg.io/' || setc || case when num ~* '^TG' then 'tg' when num ~* '^GG' then 'gg' else '' end || '/' || num || '_hires.png' from s
$_$;


ALTER FUNCTION "public"."ptcg_image_url"("p_tcgdex_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ptcg_set_code"("c" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case when c = 'sv10.5b' then 'zsv10pt5' when c = 'sv10.5w' then 'rsv10pt5' when c = 'swsh12.5' then 'swsh12pt5'
    when c ~ '^(swsh|sm)' and c like '%.5' then regexp_replace(c, '\.5$', '5')
    else regexp_replace(regexp_replace(lower(c), '([a-z]+)0*(\d)', '\1\2'), '\.5$', 'pt5') end $_$;


ALTER FUNCTION "public"."ptcg_set_code"("c" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_binder"("p_token" "text") RETURNS json
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select json_build_object(
    'owner', (select json_build_object('name', p.display_name, 'handle', p.handle) from profiles p where p.id = b.owner_id),
    'items', coalesce((select json_agg(json_build_object(
        'name', pr.name, 'set', s.name, 'number', pr.card_number, 'image', pr.image_url, 'kind', pr.kind, 'language', pr.language,
        'condition', l.condition, 'grade', l.grade, 'quantity', l.quantity, 'price', l.price, 'mode', l.mode, 'note', l.note, 'photos', l.photos)
        order by pr.name)
      from listings l join products pr on pr.id = l.product_id left join sets s on s.id = pr.set_id
      where l.owner_id = b.owner_id and l.status = 'active'), '[]'::json))
  from binder_shares b where b.token = p_token and b.enabled
$$;


ALTER FUNCTION "public"."public_binder"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reconcile_set_with_tcgp"("p_set" bigint, "p_apply" boolean DEFAULT false) RETURNS TABLE("action" "text", "n" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $_$
declare r record; k record; tgt bigint; v_lang text; v_game text; run uuid := gen_random_uuid(); nv text;
begin
  select language, game_id into v_lang, v_game from sets where id = p_set;
  if not exists (select 1 from tcgp_keys where set_id = p_set) then return; end if;

  -- 1. relabel
  for r in select o.* from product_tcgp_keys o where o.set_id = p_set and o.variant in ('Normal', 'Holofoil')
    and not exists (select 1 from tcgp_keys t where t.set_id = o.set_id and t.num = o.num and t.sub_type = o.sub_type and t.pattern = '')
  loop
    nv := case r.variant when 'Normal' then 'Holofoil' else 'Normal' end;
    if exists (select 1 from tcgp_keys t where t.set_id = p_set and t.num = r.num and t.pattern = '' and t.sub_type = nv)
       and not exists (select 1 from product_tcgp_keys o where o.set_id = p_set and o.num = r.num and o.variant = nv) then
      insert into tcgp_reconcile_log(run_id, applied, set_id, action, product_id, detail)
      values (run, p_apply, p_set, 'relabel', r.id, r.card_number || ' ' || r.name || ': ' || r.variant || ' -> ' || nv);
      if p_apply then
        update products set variant = nv,
               external_ids = external_ids || jsonb_build_object('variant_was', r.variant, 'tcgp_checked', current_date::text)
         where id = r.id;
      end if;
    end if;
  end loop;

  -- 2. add missing printings (only the three main finishes)
  for k in select distinct on (t.num, t.sub_type, t.pattern) t.* from tcgp_keys t
    where t.set_id = p_set and t.sub_type in ('Normal', 'Holofoil', 'Reverse Holofoil')
      and not exists (select 1 from product_tcgp_keys o where o.set_id = t.set_id and o.num = t.num and o.sub_type = t.sub_type and o.pattern = t.pattern)
      and not exists (select 1 from tcgp_reconcile_log l where l.run_id = run and l.action = 'relabel'
                        and l.product_id in (select o.id from product_tcgp_keys o where o.set_id = t.set_id and o.num = t.num)
                        and l.detail like '%-> ' || t.sub_type and t.pattern = '')
    order by t.num, t.sub_type, t.pattern, t.product_id
  loop
    insert into tcgp_reconcile_log(run_id, applied, set_id, action, product_id, detail)
    values (run, p_apply, p_set, 'add', k.product_id, k.number || ' ' || k.name || ' [' || tcgp_variant_label(k.sub_type, k.pattern) || ']');
    if p_apply then
      if exists (select 1 from products p where p.set_id = p_set and p.kind = 'card' and tcgp_num(p.card_number) = k.num) then
        insert into products (game_id, set_id, kind, name, name_jp, card_number, rarity, variant, language, image_url, external_ids, price_tier, special)
        select p.game_id, p.set_id, p.kind, p.name, p.name_jp, p.card_number, p.rarity, tcgp_variant_label(k.sub_type, k.pattern), p.language,
               p.image_url, jsonb_build_object('tcgplayer', k.product_id, 'tcgp_checked', current_date::text) ||
                 case when p.external_ids ? 'tcgdex' then jsonb_build_object('tcgdex', p.external_ids->>'tcgdex') else '{}'::jsonb end,
               p.price_tier, p.special
        from products p where p.set_id = p_set and p.kind = 'card' and tcgp_num(p.card_number) = k.num
        order by (p.variant in ('Normal', 'Holofoil')) desc, p.id limit 1;
      else
        insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, image_url, external_ids, price_tier)
        values (v_game, p_set, 'card',
                trim(regexp_replace(regexp_replace(k.name, '\s+-\s+[A-Za-z0-9]+(/[A-Za-z0-9-]+)?(\s.*)?$', ''), '\s*\([^)]*\)\s*$', '')),
                k.number, k.rarity, tcgp_variant_label(k.sub_type, k.pattern), v_lang,
                replace(k.image_url, '_200w.jpg', '_in_1000x1000.jpg'),
                jsonb_build_object('tcgplayer', k.product_id, 'tcgp_checked', current_date::text), 'normal');
      end if;
    end if;
  end loop;

  -- 3. remove printings TCGplayer doesn't list
  for r in select o.id, o.card_number, o.name, o.num, p.variant from product_tcgp_keys o join products p on p.id = o.id
    where o.set_id = p_set
      and p.variant !~ '^(1st Edition|Shadowless|Unlimited)'  -- TCGplayer keeps these printings in separate groups
      and not exists (select 1 from tcgp_reconcile_log l where l.run_id = run and l.action = 'relabel' and l.product_id = o.id)
      and not exists (select 1 from tcgp_keys t, tcgp_variant_key(p.variant) vk
                      where t.set_id = o.set_id and t.num = o.num and t.sub_type = vk.sub_type and t.pattern = vk.pattern)
  loop
    if product_in_use(r.id) then
      insert into tcgp_reconcile_log(run_id, applied, set_id, action, product_id, detail)
      values (run, p_apply, p_set, 'keep_owned', r.id, r.card_number || ' ' || r.name || ' [' || r.variant || ']');
      continue;
    end if;
    select p.id into tgt from products p where p.set_id = p_set and p.kind = 'card' and p.id <> r.id
      and tcgp_num(p.card_number) = r.num
      and exists (select 1 from tcgp_keys t, tcgp_variant_key(p.variant) vk where t.set_id = p_set and t.num = r.num and t.sub_type = vk.sub_type and t.pattern = vk.pattern)
    order by (p.variant = 'Normal') desc, (p.variant = 'Holofoil') desc, p.id limit 1;
    if tgt is null then
      insert into tcgp_reconcile_log(run_id, applied, set_id, action, product_id, detail)
      values (run, p_apply, p_set, 'no_sibling', r.id, r.card_number || ' ' || r.name || ' [' || r.variant || ']');
      continue;
    end if;
    insert into tcgp_reconcile_log(run_id, applied, set_id, action, product_id, detail)
    values (run, p_apply, p_set, 'remove', r.id, r.card_number || ' ' || r.name || ' [' || r.variant || ']');
    if p_apply then perform merge_product(r.id, tgt); end if;
  end loop;

  insert into tcgp_reconcile_log(run_id, applied, set_id, action, detail) values (run, p_apply, p_set, 'checked', null);
  return query select l.action, count(*)::int from tcgp_reconcile_log l where l.run_id = run and l.action <> 'checked' group by 1;
end $_$;


ALTER FUNCTION "public"."reconcile_set_with_tcgp"("p_set" bigint, "p_apply" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_card_images"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$
declare r record; probed int := 0; a jsonb; b json; c json;
begin
  -- new expansions on tcg.pokemon.com (a few per run; "no page" sets are retried monthly)
  for r in select s.id from sets s left join pcom_expansions e on e.set_id = s.id
           where s.game_id = 'pokemon' and s.language = 'EN' and s.release_date > current_date - 730 and not coalesce(s.hidden, false)
             and s.code !~ '(p|mee|sve|tg|gg)$'
             and (e.set_id is null or (e.code is null and e.checked_at < now() - interval '30 days'))
           order by s.release_date desc limit 3 loop
    perform probe_pcom_expansion(r.id); probed := probed + 1;
  end loop;
  a := upgrade_images_tcg_pcom(200);
  b := upgrade_pokemon_images(150);
  c := probe_ptcg_alt(40);
  return jsonb_build_object('expansions_probed', probed, 'tcg_pokemon_com', a, 'pokemontcg_io', b, 'ptcg_alt', c);
end $_$;


ALTER FUNCTION "public"."refresh_card_images"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_fx"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare body jsonb; k text;
begin
  body := (select content::jsonb from extensions.http_get('https://api.frankfurter.app/latest?from=AUD&to=USD,GBP,JPY,EUR,CAD,NZD,SGD,HKD,CNY,KRW,CHF'));
  for k in select jsonb_object_keys(body->'rates') loop
    insert into fx_rates (currency, aud_per_unit, updated_at) values (k, round(1 / (body->'rates'->>k)::numeric, 8), now())
    on conflict (currency) do update set aud_per_unit = excluded.aud_per_unit, updated_at = now();
  end loop;
  update fx_rates set updated_at = now() where currency = 'AUD';
end $$;


ALTER FUNCTION "public"."refresh_fx"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_set_covers"() RETURNS integer
    LANGUAGE "sql"
    AS $_$
  with c as (
    select distinct on (set_id) set_id, image_url from products
    where image_url is not null and set_id is not null
    order by set_id, (kind = 'card') desc,
      nullif(substring(split_part(card_number, '/', 1) from '(\d+)\D*$'), '')::numeric desc nulls last, id),
  u as (update sets s set cover_url = c.image_url from c where c.set_id = s.id and s.cover_url is distinct from c.image_url returning 1)
  select count(*)::int from u
$_$;


ALTER FUNCTION "public"."refresh_set_covers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reverse_pattern_label"("foil" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select 'Reverse Holofoil (' || case
           when lower(foil) = 'pokeball' then 'Poké Ball'
           when lower(foil) = 'energy' then 'Energy'
           when lower(foil) ~ '^[a-z]+ball$' then initcap(regexp_replace(lower(foil), 'ball$', '')) || ' Ball'
           else initcap(replace(replace(foil, '-', ' '), '_', ' ')) end || ')' $_$;


ALTER FUNCTION "public"."reverse_pattern_label"("foil" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_catalog_checks"("max_sets" integer DEFAULT 40) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare r record; n int := 0; m jsonb; y jsonb;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  for r in select s.id from sets s left join set_checklist_runs c on c.set_id = s.id
           where s.game_id = 'pokemon' and not coalesce(s.hidden, false) and s.series_id <> 24
             and exists (select 1 from products p where p.set_id = s.id)
             and (c.set_id is null or (s.release_date > current_date - 365 and c.checked_at < now() - interval '25 days'))
           order by c.set_id is not null, s.release_date desc nulls last limit max_sets loop
    begin perform fill_bulba_checklist(r.id); n := n + 1; exception when others then null; end;
  end loop;
  m := check_magic_counts();
  y := check_ygo_counts();
  insert into sync_log (game_id, items, note) values (null, n, 'catalog checks: magic ' || m::text || ' yugioh ' || y::text);
  return jsonb_build_object('pokemon_checklists', n, 'magic', m, 'yugioh', y);
end $$;


ALTER FUNCTION "public"."run_catalog_checks"("max_sets" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."safe_ts"("v" "text") RETURNS timestamp with time zone
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
  if v is null then return null; end if;
  return (case when v ~ '^[A-Za-z]{3}, ' then substring(v from 6) else v end)::timestamptz;
exception when others then return null;
end $$;


ALTER FUNCTION "public"."safe_ts"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."screen_ask_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare med numeric; mad numeric; n int;
begin
  select percentile_cont(0.5) within group (order by price), count(*) into med, n
  from ask_listings where product_id=p_product and market=p_market and condition=p_condition and grade=p_grade and not excluded;
  if n < 4 or med is null or med = 0 then return; end if;
  select percentile_cont(0.5) within group (order by abs(price - med)) into mad
  from ask_listings where product_id=p_product and market=p_market and condition=p_condition and grade=p_grade and not excluded;
  update ask_listings s set excluded = true,
     exclusion_reason = case when s.price > med then 'Price far above the typical asking price' else 'Price far below the typical asking price' end
       || ' (typical ' || to_char(med, 'FM999990.00') || ')'
  where s.product_id=p_product and s.market=p_market and s.condition=p_condition and s.grade=p_grade and not s.excluded
    and (s.price > med * 2.5 or s.price < med * 0.4 or (mad > 0 and abs(s.price - med) > 3 * 1.4826 * mad));
end $$;


ALTER FUNCTION "public"."screen_ask_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."screen_sold_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare med numeric; mad numeric; n int;
begin
  update sold_listings s set excluded = sold_title_flag(s.title, s.grade) is not null, exclusion_reason = sold_title_flag(s.title, s.grade)
  where s.product_id = p_product and s.market = p_market and s.condition = p_condition and s.grade = p_grade;

  select percentile_cont(0.5) within group (order by price), count(*) into med, n
  from (select price from sold_listings where product_id = p_product and market = p_market and condition = p_condition and grade = p_grade
          and not excluded and user_decision is distinct from 'exclude' order by sold_at desc limit 20) x;
  if n < 4 or med is null or med = 0 then return; end if;

  select percentile_cont(0.5) within group (order by abs(price - med)) into mad
  from (select price from sold_listings where product_id = p_product and market = p_market and condition = p_condition and grade = p_grade
          and not excluded and user_decision is distinct from 'exclude' order by sold_at desc limit 20) x;

  update sold_listings s set excluded = true,
         exclusion_reason = case when s.price > med then 'Price far above the typical sale' else 'Price far below the typical sale' end
           || ' (typical ' || to_char(med, 'FM999990.00') || ')'
  where s.product_id = p_product and s.market = p_market and s.condition = p_condition and s.grade = p_grade and not s.excluded
    and (s.price > med * 2.5 or s.price < med * 0.4
         or (mad > 0 and abs(s.price - med) > 3 * 1.4826 * mad));
end $$;


ALTER FUNCTION "public"."screen_sold_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."scryfall_get"("url" "text") RETURNS "jsonb"
    LANGUAGE "sql"
    AS $$
  select content::jsonb from extensions.http((
    'GET', url,
    array[extensions.http_header('User-Agent','tcg-collector/0.1'), extensions.http_header('Accept','application/json')],
    null, null)::extensions.http_request)
$$;


ALTER FUNCTION "public"."scryfall_get"("url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sealed_title_flag"("title" "text", "pname" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select coalesce(
    sold_title_flag(case when pname ~* '\mbundle\M' then regexp_replace(title, '\mbundle\M', '', 'gi') else title end, ''),
    ask_lot_flag(title),
    (select 'Title includes another product (' || t || ')' from unnest(array['booster bundle','elite trainer box','etb','booster box']) t
      where title ~* ('\m' || t || '\M') and pname !~* ('\m' || t || '\M') and not (t = 'etb' and pname ~* 'elite trainer box') limit 1),
    (select 'Missing "' || w || '" in title' from regexp_split_to_table(lower(regexp_replace(pname, '[^A-Za-z0-9 ]', ' ', 'g')), '\s+') w
      where length(w) >= 4 and w not in ('pokemon','with','from','card','cards','game','edition')
        and lower(title) !~ w limit 1)) $$;


ALTER FUNCTION "public"."sealed_title_flag"("title" "text", "pname" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_completion"() RETURNS TABLE("set_id" bigint, "total" integer, "owned" integer, "total_value" numeric, "owned_value" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  with px as (
    select product_id, max(median) filter (where grade = '' and condition in ('NM','Sealed')) as v from price_v group by product_id
  ), mine as (
    select distinct product_id from collection_items where owner_id = auth.uid()
  ), own as (
    select p.set_id, count(*)::int as n, sum(px.v) as ov from mine join products p on p.id = mine.product_id and p.kind = 'card'
    left join px on px.product_id = p.id group by p.set_id
  ), val as (
    select p.set_id, sum(px.v) as tv from px join products p on p.id = px.product_id and p.kind = 'card' group by p.set_id
  )
  select t.set_id, t.total, coalesce(own.n, 0), coalesce(val.tv, 0), coalesce(own.ov, 0)
  from set_card_totals t left join own on own.set_id = t.set_id left join val on val.set_id = t.set_id
$$;


ALTER FUNCTION "public"."set_completion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sets_english_name"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
declare e text;
begin
  if new.language = 'JP' and new.name ~ '[ぁ-んァ-ン一-龯]' then
    select en into e from jp_set_names where jp_norm(jp) = jp_norm(new.name) limit 1;
    if e is not null and exists (select 1 from sets x where x.game_id = new.game_id and x.name = e and x.id is distinct from new.id) then e := e || ' (JP)'; end if;
    if e is not null and not exists (select 1 from sets x where x.game_id = new.game_id and x.name = e and x.id is distinct from new.id) then
      new.name_jp := regexp_replace(new.name, '\s*\(JP\)\s*$', ''); new.name := e;
    end if;
  end if;
  return new;
end $_$;


ALTER FUNCTION "public"."sets_english_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sets_inherit_hidden"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.series_id is not null and exists (select 1 from series where id = new.series_id and hidden) then new.hidden := true; end if;
  return new;
end $$;


ALTER FUNCTION "public"."sets_inherit_hidden"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."snapshot_portfolio"("p_day" "date" DEFAULT CURRENT_DATE) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare n int;
begin
  insert into portfolio_snapshots (owner_id, day, set_id, game_id, kind, language, items, value, priced_items, source)
  select c.owner_id, p_day, coalesce(p.set_id, 0), p.game_id, p.kind, p.language,
         sum(c.quantity), coalesce(sum(c.quantity * coalesce(pr.median, ps.median)), 0),
         coalesce(sum(case when coalesce(pr.median, ps.median) is not null then c.quantity end), 0), 'daily'
  from collection_items c
  join products p on p.id = c.product_id
  left join price_v pr on pr.product_id = c.product_id and pr.condition = c.condition and pr.grade = c.grade
  left join price_v ps on p.kind = 'sealed' and ps.product_id = c.product_id and ps.condition = 'Sealed' and ps.grade = ''
  where c.owner_id is not null
  group by c.owner_id, coalesce(p.set_id, 0), p.game_id, p.kind, p.language
  on conflict (owner_id, day, set_id, kind, language) do update
    set items = excluded.items, value = excluded.value, priced_items = excluded.priced_items, source = 'daily';
  get diagnostics n = row_count;
  return n;
end $$;


ALTER FUNCTION "public"."snapshot_portfolio"("p_day" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sold_after_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare g record;
begin
  for g in select distinct product_id, market, condition, grade from new_rows loop
    perform screen_sold_group(g.product_id, g.market, g.condition, g.grade);
  end loop;
  return null;
end $$;


ALTER FUNCTION "public"."sold_after_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sold_is_credible"("excluded" boolean, "user_decision" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$ select case when user_decision = 'include' then true when user_decision = 'exclude' then false else not excluded end $$;


ALTER FUNCTION "public"."sold_is_credible"("excluded" boolean, "user_decision" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sold_title_flag"("title" "text", "grade" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when title ~* '\m(proxy|custom|fan ?art|replica|reprint|fake|orica|not (genuine|real|official))\M' then 'Title suggests a non-genuine item'
    when title ~* '\m(lot|bundle|x[2-9]|[2-9]x|set of|collection of|playset|bulk)\M' then 'Title suggests multiple items / a lot'
    when title ~* '\m(empty|box only|no cards|opened|resealed|code card only|digital|online code)\M' then 'Title suggests empty, opened or code-only'
    when title ~* '\m(damaged|creased|water damage|heavily played|poor)\M' and coalesce(grade,'') = '' then 'Title suggests damage'
    when coalesce(grade,'') = '' and title ~* '\m(psa|bgs|cgc|beckett|sgc|ace)\s*(10|9\.5|9|8)' then 'Graded copy mixed into raw results'
    when coalesce(grade,'') <> '' and title !~* replace(grade, ' ', '\s*') then 'Grade in title doesn''t match'
  end $$;


ALTER FUNCTION "public"."sold_title_flag"("title" "text", "grade" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."strip_num"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select norm(regexp_replace(coalesce(t,''), '\s*-\s*(OP|ST|EB|PRB|P)?[0-9]*-?[0-9]{3}\b|\s*\([0-9]{3}\)', '', 'gi')) $$;


ALTER FUNCTION "public"."strip_num"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_jp_bulbapedia"("sid" bigint, "official" integer) RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare s record; page text; w text; n int; denom int;
begin
  select * into s from sets where id = sid;
  if official is null then return 0; end if;
  page := replace(replace(regexp_replace(s.name, '\s*\(JP\)|\s+SM\d\+$', '', 'g'), ' ', '_'), '&', '%26') || '_(TCG)';
  select content::jsonb->'parse'->>'wikitext' into w from extensions.http_get(
    'https://bulbapedia.bulbagarden.net/w/api.php?action=parse&prop=wikitext&format=json&formatversion=2&page=' || page);
  if w is null or w ~ '^#REDIRECT' then return 0; end if;
  denom := (regexp_match(w, '\{\{Setlist/n?m?entry\|\d+/(\d+)\|'))[1]::int;
  if denom is distinct from official then return 0; end if;
  insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, external_ids)
  select distinct on (x.num) 'pokemon', sid, 'card', x.nm, x.num, nullif(trim(x.rar), 'None'), '', 'JP', jsonb_build_object('bulbapedia', page || '#' || x.num)
  from (
    -- {{TCG ID|Set|Name|N}}
    select split_part(m[1], '/', 1) num, m[2] nm, m[3] rar from regexp_matches(w,
      '\{\{Setlist/n?m?entry\|(\d+/\d+)\|(?:[A-Z—]\|)?\{\{TCG ID\|[^|]+\|([^|}]+)\|[^}]*\}\}\|[^|}]*\|[^|}]*\|([^|}]*)\}\}', 'g') m
    union all
    -- [[Name-GX (Set N)|Name]]{{GX}}, incl. Unit Energy {{e|…}} symbols
    select split_part(m[1], '/', 1), m[2], m[3] from regexp_matches(w,
      '\{\{Setlist/n?m?entry\|(\d+/\d+)\|(?:[A-Z—]\|)?\[\[([^|\]()]+) \([^)]*\)(?:\|[^\]]*)?\]\](?:[^|{]|\{\{[A-Za-z ]+\}\}|\{\{e\|[A-Za-z]+\}\})*\|[^|}]*\|[^|}]*\|([^|}]*)\}\}', 'g') m
  ) x
  where not exists (select 1 from products p where p.set_id = sid and card_key(p.card_number) = card_key(x.num))
  order by x.num
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $_$;


ALTER FUNCTION "public"."sync_jp_bulbapedia"("sid" bigint, "official" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_jp_limitless"("sid" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare s record; resp record; n int;
begin
  select * into s from sets where id = sid;
  if s.code is null then return 0; end if;
  select status, content into resp from extensions.http_get('https://limitlesstcg.com/cards/jp/' || replace(s.code, '+', '%2B') || '?display=list');
  if resp.status <> 200 then return 0; end if;
  insert into products (game_id, set_id, kind, name, name_jp, card_number, rarity, variant, language, image_url, external_ids)
  select 'pokemon', sid, 'card', coalesce(jp_card_name_en2(x.nm), x.nm), case when x.nm ~ '[ぁ-んァ-ヶ一-龯]' then x.nm end,
         case when x.num ~ '^\d+$' then lpad(x.num, 3, '0') else x.num end, x.rarity, '', 'JP', x.img,
         jsonb_build_object('limitless', s.code || '/' || x.num)
  from (select (regexp_match(r, '<td><a href="/cards/jp/[^/"]+/([^"?]+)">'))[1] num,
               replace(replace(replace((regexp_match(r, '</a></td>\s*<td><a href="[^"]+">([^<]+)</a></td>'))[1], '&amp;', '&'), '&#039;', ''''), '&quot;', '"') nm,
               nullif(trim((regexp_match(r, '<td class="md-only"><a href="[^"]+">([^<]*)</a></td>'))[1]), '') rarity,
               replace((regexp_match(r, '^"([^"]+)"'))[1], '_XS.png', '_LG.png') img
        from regexp_split_to_table(resp.content, '<tr data-hover=') with ordinality t(r, i) where i > 1) x
  where x.num is not null and x.nm is not null
    and not exists (select 1 from products p where p.set_id = sid and card_key(p.card_number) = card_key(x.num))
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $_$;


ALTER FUNCTION "public"."sync_jp_limitless"("sid" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_one_set"("sid" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  s record; body jsonb; url text; pages int := 0; n int := 0; added int; cs text; tcg text; pg int; got int; total int;
  expected int; have int; note text := 'ok'; rel date;
begin
  select * into s from sets where id = sid;
  perform http_setup();

  if s.game_id = 'pokemon' and s.code is not null then
    body := (select content::jsonb from extensions.http_get(
      'https://api.tcgdex.net/v2/' || case when s.language = 'JP' then 'ja' else 'en' end || '/sets/' || replace(s.code, '+', '%2B')));
    -- JP sets: English name in `name`, Japanese kept in `name_jp`
    insert into products (game_id, set_id, kind, name, name_jp, card_number, language, image_url, external_ids)
    select 'pokemon', sid, 'card',
           case when s.language = 'JP' then coalesce(jp_card_name_en2(x->>'name'), x->>'name') else x->>'name' end,
           case when s.language = 'JP' and x->>'name' ~ '[ぁ-んァ-ヶ一-龯]' then x->>'name' end,
           x->>'localId', s.language,
           case when x->>'image' is not null then (x->>'image') || '/high.webp' end,
           jsonb_build_object('tcgdex', x->>'id')
    from jsonb_array_elements(coalesce(body->'cards', '[]'::jsonb)) x
    where not exists (select 1 from catalog_exclusions e where e.tcgdex_id = x->>'id')
      and not exists (select 1 from products p where p.set_id = sid
                        and (p.external_ids->>'tcgdex' = x->>'id'
                             or (card_key(p.card_number) = card_key(x->>'localId')
                                 and (norm(p.name) = norm(x->>'name') or norm(p.name_jp) = norm(x->>'name')))))
    on conflict do nothing;
    get diagnostics n = row_count;
    if s.language = 'JP' and jsonb_array_length(coalesce(body->'cards', '[]'::jsonb)) = 0 then n := n + sync_jp_limitless(sid); end if;  -- TCGdex lists the set but has no cards
    if s.language = 'JP' and not exists (select 1 from products where set_id = sid) then n := n + sync_jp_bulbapedia(sid, nullif(body->'cardCount'->>'official', '')::int); end if;  -- last resort
    -- rarity, variants (incl. reverse holos) and "NNN/total" numbers are filled by enrich_pokemon_cards()
    if body ? 'releaseDate' then update sets set release_date = coalesce(release_date, left(body->>'releaseDate',10)::date) where id = sid; end if;
    expected := nullif(body->'cardCount'->>'total','')::int;
    select count(distinct card_key(card_number)) into have from products where set_id = sid and kind = 'card';
    if expected is not null and have < expected then note := 'SHORT ' || have || '/' || expected;
    elsif expected is not null then note := 'ok ' || have || '/' || expected; end if;

  elsif s.game_id = 'magic' and s.code is not null then
    url := 'https://api.scryfall.com/cards/search?q=' || extensions.urlencode('e:' || s.code || ' unique:prints include:extras include:variations') || '&order=set';
    loop
      exit when url is null or pages >= 40;
      pages := pages + 1;
      body := scryfall_get(url);
      exit when body->>'object' = 'error';
      -- existing rows with no variant: give them their first finish
      update products p set variant = mtg_finish(c->'finishes'->>0)
      from jsonb_array_elements(coalesce(body->'data', '[]'::jsonb)) c
      where p.set_id = sid and p.external_ids->>'scryfall' = c->>'id' and coalesce(p.variant,'') = ''
        and jsonb_array_length(coalesce(c->'finishes','[]'::jsonb)) > 0;
      -- one row per finish (Normal / Foil / Etched Foil)
      insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, image_url, external_ids)
      select 'magic', sid, 'card', c->>'name', c->>'collector_number', initcap(c->>'rarity'), mtg_finish(f), 'EN',
             coalesce(c->'image_uris'->>'normal', c->'card_faces'->0->'image_uris'->>'normal'),
             jsonb_build_object('scryfall', c->>'id')
      from jsonb_array_elements(coalesce(body->'data', '[]'::jsonb)) c
      cross join lateral jsonb_array_elements_text(coalesce(c->'finishes', '["nonfoil"]'::jsonb)) f
      where not exists (select 1 from products p where p.set_id = sid and p.variant = mtg_finish(f)
                          and (p.external_ids->>'scryfall' = c->>'id'
                               or (ltrim(p.card_number,'0') = ltrim(c->>'collector_number','0') and norm(p.name) = norm(c->>'name'))))
      on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
      url := case when (body->>'has_more')::boolean then body->>'next_page' end;
      perform pg_sleep(0.12);
    end loop;
    if url is not null then note := 'SHORT page cap reached'; end if;

  elsif s.game_id = 'yugioh' then
    body := (select content::jsonb from extensions.http_get(
      'https://db.ygoprodeck.com/api/v7/cardinfo.php?cardset=' || extensions.urlencode(s.name)));
    insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, external_ids)
    select distinct on (x->>'set_code', x->>'set_rarity') 'yugioh', sid, 'card', c->>'name', x->>'set_code', x->>'set_rarity', coalesce(x->>'set_rarity',''), 'EN',
           jsonb_build_object('ygoprodeck', c->>'id')
    from jsonb_array_elements(coalesce(body->'data', '[]'::jsonb)) c
    cross join lateral jsonb_array_elements(coalesce(c->'card_sets', '[]'::jsonb)) x
    where x->>'set_name' = s.name
      and not exists (select 1 from products p where p.set_id = sid and p.card_number = x->>'set_code' and norm(p.name) = norm(c->>'name'))
    order by x->>'set_code', x->>'set_rarity'
    on conflict do nothing;
    get diagnostics n = row_count;

  elsif s.game_id in ('one-piece','dragon-ball') then
    for cs, tcg, rel in select l.catalog_set, c.series, c.release_date from set_links l join catalog_sets c on c.source='apitcg' and c.id = l.catalog_set where l.set_id = sid loop
      -- fetch once, then again monthly while the set is under a year old
      if not exists (select 1 from catalog_fetch_log f where f.source='apitcg' and f.catalog_set = cs
                       and (f.fetched_at > now() - interval '30 days' or coalesce(rel, current_date) < current_date - 365)) then
        pg := 1; got := 0; total := null;
        loop
          -- free plan: stay under 25 API TCG requests a day; a half-read set is not marked fetched
          if coalesce((select requests from api_usage where day = current_date and source='apitcg'), 0) >= 25 then
            raise exception 'apitcg daily budget used (partial %: %/%)', cs, got, coalesce(total::text,'?');
          end if;
          body := apitcg_get('/api/products?tcg=' || tcg || '&set=' || cs || '&limit=100&page=' || pg);
          insert into api_usage (day, source, requests) values (current_date, 'apitcg', 1)
          on conflict (day, source) do update set requests = api_usage.requests + 1;
          exit when body->'data' is null or jsonb_array_length(body->'data') = 0;
          insert into catalog_cards (source, lang, set_code, id, local_id, name, image, kind, rarity)
          select 'apitcg','en', cs, x->>'_id', coalesce(x->>'code',''), x->>'name', x->'images'->0->>'large',
                 case when x->>'type' ilike '%sealed%' then 'sealed' else 'card' end, x->'attributes'->>'Rarity'
          from jsonb_array_elements(body->'data') x
          on conflict (source, lang, id) do update set image = excluded.image, kind = excluded.kind, rarity = excluded.rarity, name = excluded.name;
          got := got + jsonb_array_length(body->'data');
          total := coalesce((body->>'total')::int, got);
          exit when got >= total or pg >= 40;
          pg := pg + 1;
        end loop;
        if total is not null and got < total then note := 'SHORT ' || got || '/' || total; end if;
        insert into catalog_fetch_log (source, catalog_set, items) values ('apitcg', cs, got)
        on conflict (source, catalog_set) do update set items = excluded.items, fetched_at = now();
      end if;
      -- fill rarity / variant on rows we already hold
      update products p set rarity = coalesce(p.rarity, cc.rarity),
             variant = case when coalesce(p.variant,'') = '' and p.kind = 'card' then op_variant(p.name) else p.variant end
      from catalog_cards cc
      where cc.source='apitcg' and cc.set_code = cs and p.set_id = sid and p.external_ids->>'apitcg' = cc.id
        and (p.rarity is null or coalesce(p.variant,'') = '');
      insert into products (game_id, set_id, kind, name, card_number, rarity, variant, language, image_url, external_ids)
      select s.game_id, sid, coalesce(cc.kind, case when cc.local_id = '' then 'sealed' else 'card' end), cc.name, cc.local_id,
             cc.rarity, case when coalesce(cc.kind,'card') = 'card' and cc.local_id <> '' then op_variant(cc.name) else '' end,
             s.language, cc.image, jsonb_build_object('apitcg', cc.id)
      from catalog_cards cc
      where cc.source='apitcg' and cc.set_code = cs
        and not exists (select 1 from products p where p.set_id = sid
                          and (p.external_ids->>'apitcg' = cc.id or p.external_ids->>'apitcg_en_image' = cc.id
                               or (p.card_number = cc.local_id and strip_num(p.name) = strip_num(cc.name))))
      on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end loop;
  end if;

  update sets set synced_at = now(), sync_attempts = case when note like 'SHORT%' then sync_attempts + 1 else 0 end,
         sync_note = case when note like 'SHORT%' then note end where id = sid;
  insert into sync_log (set_id, game_id, items, note) values (sid, s.game_id, n, note);
  return n;
end $$;


ALTER FUNCTION "public"."sync_one_set"("sid" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_set_lists"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare lg text; sr record; body jsonb; sid bigint; setx jsonb; t text; pg int; resp jsonb; got int; total int;
begin
  perform http_setup();
  -- Pokemon (English + Japanese)
  foreach lg in array array['en','ja'] loop
    for sr in select x->>'id' as id, x->>'name' as name, ord
              from jsonb_array_elements((select content::jsonb from extensions.http_get('https://api.tcgdex.net/v2/' || lg || '/series'))) with ordinality q(x, ord)
    loop
      begin
        body := (select content::jsonb from extensions.http_get('https://api.tcgdex.net/v2/' || lg || '/series/' || sr.id));
      exception when others then continue; end;
      insert into series (game_id, name, sort_order) values ('pokemon', sr.name || case when lg='ja' then ' (JP)' else '' end, sr.ord)
      on conflict (game_id, name) do update set sort_order = excluded.sort_order returning id into sid;
      for setx in select * from jsonb_array_elements(coalesce(body->'sets','[]'::jsonb)) loop
        if not exists (select 1 from sets where game_id='pokemon' and lower(code) = lower(setx->>'id') and language = case when lg='ja' then 'JP' else 'EN' end) then
          -- an English set takes its name back from a Japanese set that borrowed it
          if lg = 'en' then update sets set name = name || ' (JP)' where game_id='pokemon' and language='JP' and name = setx->>'name'; end if;
          insert into sets (game_id, series_id, name, code, language)
          values ('pokemon', sid, (setx->>'name') || case when lg='ja' and exists (select 1 from sets where game_id='pokemon' and name=setx->>'name') then ' (JP)' else '' end,
                  setx->>'id', case when lg='ja' then 'JP' else 'EN' end)
          on conflict (game_id, name) do nothing;
        end if;
      end loop;
    end loop;
  end loop;

  -- Magic
  insert into series (game_id, name)
  select distinct 'magic', initcap(replace(s->>'set_type','_',' '))
  from jsonb_array_elements(scryfall_get('https://api.scryfall.com/sets')->'data') s
  where not coalesce((s->>'digital')::boolean, false)
  on conflict do nothing;
  insert into sets (game_id, series_id, name, code, release_date, language)
  select 'magic', sr.id, s->>'name', s->>'code', (s->>'released_at')::date, 'EN'
  from jsonb_array_elements(scryfall_get('https://api.scryfall.com/sets')->'data') s
  join series sr on sr.game_id='magic' and sr.name = initcap(replace(s->>'set_type','_',' '))
  where not coalesce((s->>'digital')::boolean, false)
    and not exists (select 1 from sets x where x.game_id='magic' and x.code = s->>'code')
  on conflict (game_id, name) do nothing;

  -- Yu-Gi-Oh
  insert into series (game_id, name, sort_order)
  select distinct 'yugioh', coalesce(extract(year from nullif(x->>'tcg_date','')::date)::int::text || ' releases', 'Undated'),
         coalesce(extract(year from nullif(x->>'tcg_date','')::date)::int, 0)
  from jsonb_array_elements((select content::jsonb from extensions.http_get('https://db.ygoprodeck.com/api/v7/cardsets.php'))) x
  on conflict (game_id, name) do nothing;
  insert into sets (game_id, series_id, name, code, release_date, language)
  select distinct on (x->>'set_name') 'yugioh', sr.id, x->>'set_name', x->>'set_code', nullif(x->>'tcg_date','')::date, 'EN'
  from jsonb_array_elements((select content::jsonb from extensions.http_get('https://db.ygoprodeck.com/api/v7/cardsets.php'))) x
  join series sr on sr.game_id='yugioh' and sr.name = coalesce(extract(year from nullif(x->>'tcg_date','')::date)::int::text || ' releases', 'Undated')
  order by x->>'set_name'
  on conflict (game_id, name) do nothing;

  -- One Piece + Dragon Ball (3 requests)
  foreach t in array array['one-piece','dragon-ball-super-fusion-world','dragon-ball-super-masters'] loop
    pg := 1; got := 0;
    loop
      resp := apitcg_get('/api/' || t || '/sets?limit=100&page=' || pg);
      insert into api_usage (day, source, requests) values (current_date, 'apitcg', 1)
      on conflict (day, source) do update set requests = api_usage.requests + 1;
      exit when resp->'data' is null or jsonb_array_length(resp->'data') = 0;
      insert into catalog_sets (source, lang, id, name, series, release_date, code)
      select 'apitcg','en', x->>'_id', x->>'name', t, left(x->>'release_date',10)::date, x->>'code'
      from jsonb_array_elements(resp->'data') x
      on conflict (source, lang, id) do update set code = excluded.code, release_date = excluded.release_date;
      got := got + jsonb_array_length(resp->'data');
      total := coalesce((resp->>'total')::int, got);
      exit when got >= total or pg >= 4;
      pg := pg + 1;
    end loop;
  end loop;
  insert into series (game_id, name)
  select distinct case when c.series='one-piece' then 'one-piece' else 'dragon-ball' end, catalog_series_name(c.series, c.code)
  from catalog_sets c where c.source='apitcg' on conflict do nothing;
  insert into sets (game_id, series_id, name, code, release_date, language)
  select x.g, sr.id, c.name, c.code, c.release_date, 'EN'
  from catalog_sets c
  cross join lateral (select case when c.series='one-piece' then 'one-piece' else 'dragon-ball' end g) x
  join series sr on sr.game_id = x.g and sr.name = catalog_series_name(c.series, c.code)
  where c.source='apitcg' and not exists (select 1 from set_links l where l.catalog_set = c.id)
  on conflict (game_id, name) do nothing;
  insert into set_links (set_id, source, catalog_set)
  select s.id, 'apitcg', c.id from catalog_sets c join sets s on s.name = c.name and s.language = 'EN'
    and s.game_id = case when c.series='one-piece' then 'one-piece' else 'dragon-ball' end
  where c.source='apitcg' on conflict do nothing;

  insert into sync_log (game_id, items, note) values (null, 0, 'set lists refreshed');
end $$;


ALTER FUNCTION "public"."sync_set_lists"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_tick"("max_sets" integer DEFAULT 6) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare r record; done int := 0;
begin
  for r in
    select id, game_id from sets
    where sync_attempts < 3
      and (synced_at is null
           or (release_date > current_date - 120 and synced_at < now() - interval '7 days')
           or synced_at < now() - interval '60 days')                 -- older sets are revisited every ~2 months
      and (code is not null or game_id in ('yugioh','one-piece','dragon-ball'))
    order by (synced_at is not null),
             exists (select 1 from collection_items ci join products p on p.id = ci.product_id where p.set_id = sets.id) desc,
             release_date desc nulls last, id
    limit max_sets
  loop
    begin
      perform sync_one_set(r.id);
    exception when others then
      update sets set sync_attempts = sync_attempts + 1, sync_note = left(sqlerrm, 200) where id = r.id;
      insert into sync_log (set_id, game_id, items, note) values (r.id, r.game_id, 0, left(sqlerrm, 200));
      if sqlerrm like '%budget%' then update sets set sync_attempts = sync_attempts - 1 where id = r.id; end if;
    end;
    done := done + 1;
  end loop;
  return done;
end $$;


ALTER FUNCTION "public"."sync_tick"("max_sets" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgdex_variant_labels"("vd" "jsonb") RETURNS TABLE("label" "text", "kind" "text")
    LANGUAGE "sql" IMMUTABLE
    AS $$
  with e as (
    select x.v, x.i, x.v->>'type' t, nullif(x.v->>'foil', '') foil,
           x.v->'thirdParty'->>'tcgplayer' tcp, x.v->'thirdParty'->>'cardmarket' cm
    from jsonb_array_elements(coalesce(vd, '[]'::jsonb)) with ordinality x(v, i)
    where coalesce(x.v->>'size', 'standard') = 'standard'
      and jsonb_typeof(x.v->'stamp') is distinct from 'array' and coalesce(x.v->>'stamp', '') = ''),
  base as (select array_agg(distinct cm) cms, bool_or(tcp is not null) any_tcp from e where tcp is not null and foil is null),
  rev as (select array_agg(foil order by i) fs from e where t = 'reverse' and foil is not null)
  select distinct on (label) label, kind from (
    select case
             when e.t = 'reverse' then
               case when coalesce(array_length((select fs from rev), 1), 0) > 1 then reverse_pattern_label(e.foil) else 'Reverse Holofoil' end
             when e.t in ('normal', 'holo') and e.foil is not null then
               (case e.t when 'holo' then 'Holofoil' else 'Normal' end) || ' (' || initcap(replace(e.foil, '-', ' ')) || ')'
             when e.t in ('normal', 'holo') and e.tcp is null and coalesce((select any_tcp from base), false)
                  and not (e.cm = any(coalesce((select cms from base), '{}'))) then
               (case e.t when 'holo' then 'Holofoil' else 'Non-Holofoil' end) || ' (Exclusive)'
             when e.t = 'normal' then 'Normal'
             when e.t = 'holo' then 'Holofoil'
             when e.t = 'firstEdition' then '1st Edition'
           end label,
           case when e.t = 'reverse' or (e.foil is null and (e.tcp is not null or not coalesce((select any_tcp from base), false)
                     or e.cm = any(coalesce((select cms from base), '{}')))) then 'booster' else 'exclusive' end kind
    from e) z
  where label is not null
  order by label, kind $$;


ALTER FUNCTION "public"."tcgdex_variant_labels"("vd" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_allows"("p_set" bigint, "p_number" "text", "p_variant" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select not exists (select 1 from tcgp_keys t where t.set_id = p_set)
      or exists (select 1 from tcgp_keys t, tcgp_variant_key(p_variant) k
                 where t.set_id = p_set and t.num = tcgp_num(p_number) and t.sub_type = k.sub_type and t.pattern = k.pattern) $$;


ALTER FUNCTION "public"."tcgp_allows"("p_set" bigint, "p_number" "text", "p_variant" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_norm"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select regexp_replace(lower(translate(regexp_replace(t, '^[A-Za-z]{1,4}[0-9.]*[a-z]?:\s*', ''), 'éÉ’''&', 'ee  ')), '[^a-z0-9]+', '', 'g') $$;


ALTER FUNCTION "public"."tcgp_norm"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_num"("n" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select lower(regexp_replace(split_part(coalesce(n,''), '/', 1), '^0+(?=.)', '')) $$;


ALTER FUNCTION "public"."tcgp_num"("n" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_our_tag"("p_name" "text", "p_variant" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select coalesce(string_agg(distinct x, '|' order by x), '') from (
    select unnest(string_to_array(nullif(tcgp_promo_tag(p_name), ''), '|')) x
    union select 'cosmos holo' where p_variant = 'Holofoil (Cosmos)'
    union select 'cracked ice holo' where p_variant = 'Holofoil (Cracked Ice)') z $$;


ALTER FUNCTION "public"."tcgp_our_tag"("p_name" "text", "p_variant" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_pattern"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case when t is null then '' else
    regexp_replace(regexp_replace(lower(translate(t, 'é', 'e')), '\s*symbol pattern$|\s*pattern$', ''), '\s+', ' ', 'g') end $_$;


ALTER FUNCTION "public"."tcgp_pattern"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_promo_tag"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  -- the product-level tags TCGplayer puts in brackets, normalised (e.g. "pokemon center exclusive|staff")
  select coalesce(string_agg(lower(translate(m[1], 'é', 'e')), '|' order by m[1]), '')
  from regexp_matches(coalesce(t, ''), '[\(\[]((?:pokemon center exclusive|staff|winner|prerelease|cosmos holo|cracked ice holo|league|championship|stamped)[^\)\]]*)[\)\]]', 'gi') m $$;


ALTER FUNCTION "public"."tcgp_promo_tag"("t" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_their_tag"("p_name" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select coalesce(string_agg(distinct x, '|' order by x), '') from unnest(string_to_array(nullif(tcgp_promo_tag(p_name), ''), '|')) x $$;


ALTER FUNCTION "public"."tcgp_their_tag"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_variant_key"("v" "text") RETURNS TABLE("sub_type" "text", "pattern" "text")
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case when v like 'Reverse Holofoil%' then 'Reverse Holofoil' when v in ('Holofoil (Gold)', 'Holofoil (Tinsel)') then 'Holofoil' else v end,
         case when v ~ '^Reverse Holofoil \(' then tcgp_pattern(substring(v from '\(([^)]*)\)$')) else '' end $_$;


ALTER FUNCTION "public"."tcgp_variant_key"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tcgp_variant_label"("sub_type" "text", "pattern" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case when coalesce(pattern, '') = '' then sub_type
              else 'Reverse Holofoil (' || case pattern when 'poke ball' then 'Poké Ball' when 'energy' then 'Energy'
                                                        else initcap(pattern) end || ')' end $$;


ALTER FUNCTION "public"."tcgp_variant_label"("sub_type" "text", "pattern" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trade_action"("p_id" bigint, "p_action" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare t record; me uuid := auth.uid(); it jsonb; have int;
begin
  select * into t from trade_proposals where id = p_id for update;
  if not found or me not in (t.from_user, t.to_user) then raise exception 'Trade not found'; end if;
  if p_action = 'accept' and me = t.to_user and t.status = 'proposed' then
    update trade_proposals set status = 'accepted', updated_at = now() where id = p_id;
  elsif p_action = 'decline' and me = t.to_user and t.status in ('proposed','accepted') then
    update trade_proposals set status = 'declined', updated_at = now() where id = p_id;
  elsif p_action = 'withdraw' and me = t.from_user and t.status in ('proposed','accepted') then
    update trade_proposals set status = 'withdrawn', updated_at = now() where id = p_id;
  elsif p_action = 'done' and t.status = 'accepted' then
    update trade_proposals set from_done = from_done or me = from_user, to_done = to_done or me = to_user, updated_at = now() where id = p_id
      returning * into t;
    if t.from_done and t.to_done then
      for it in select * from jsonb_array_elements(t.offered_items) loop
        select coalesce(sum(quantity),0) into have from collection_items where owner_id = t.from_user and product_id = (it->>'product_id')::bigint and condition = it->>'condition' and grade = coalesce(it->>'grade','');
        if have < (it->>'quantity')::int then raise exception 'The proposer no longer has enough of an offered card'; end if;
      end loop;
      for it in select * from jsonb_array_elements(t.requested_items) loop
        select coalesce(sum(quantity),0) into have from collection_items where owner_id = t.to_user and product_id = (it->>'product_id')::bigint and condition = it->>'condition' and grade = coalesce(it->>'grade','');
        if have < (it->>'quantity')::int then raise exception 'The other person no longer has enough of a requested card'; end if;
      end loop;
      perform move_items(t.from_user, t.to_user, t.offered_items, p_id);
      perform move_items(t.to_user, t.from_user, t.requested_items, p_id);
      update trade_proposals set status = 'completed', updated_at = now() where id = p_id;
    end if;
  else
    raise exception 'That action isn''t available for this trade';
  end if;
  return (select status from trade_proposals where id = p_id);
end $$;


ALTER FUNCTION "public"."trade_action"("p_id" bigint, "p_action" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upgrade_images_tcg_pcom"("max_n" integer DEFAULT 150) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$
declare r record; url text; st int; ok int := 0; miss int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for r in
    select p.set_id, split_part(p.card_number, '/', 1)::int num, min(e.img_slug) img_slug, min(e.code) code
    from products p join pcom_expansions e on e.set_id = p.set_id and e.code is not null
    where p.game_id = 'pokemon' and p.language = 'EN' and p.kind = 'card' and split_part(p.card_number, '/', 1) ~ '^\d+$'
      and coalesce(p.image_url, '') not like 'https://dz3we2x72f7ol.cloudfront.net/%'
      and coalesce(p.external_ids->>'tcgpcom_checked', '') < (current_date - 30)::text
    group by 1, 2
    order by bool_or(exists (select 1 from collection_items c where c.product_id = p.id)) desc, 1 desc, 2
    limit max_n
  loop
    url := 'https://dz3we2x72f7ol.cloudfront.net/expansions/' || r.img_slug || '/en-us/' || r.code || '_EN_' || r.num || '.png';
    begin select status into st from extensions.http(('HEAD', url, null, null, null)::extensions.http_request); exception when others then st := 0; end;
    if st = 200 then
      update products set external_ids = external_ids || jsonb_build_object('tcgpcom_checked', current_date::text)
             || case when image_url is not null then jsonb_build_object('prev_image', image_url) else '{}'::jsonb end,
             image_url = url
       where set_id = r.set_id and kind = 'card' and split_part(card_number, '/', 1) ~ '^\d+$' and split_part(card_number, '/', 1)::int = r.num;
      ok := ok + 1;
    else
      update products set external_ids = external_ids || jsonb_build_object('tcgpcom_checked', current_date::text)
       where set_id = r.set_id and kind = 'card' and split_part(card_number, '/', 1) ~ '^\d+$' and split_part(card_number, '/', 1)::int = r.num;
      miss := miss + 1;
    end if;
  end loop;
  return jsonb_build_object('upgraded', ok, 'not_found', miss);
end $_$;


ALTER FUNCTION "public"."upgrade_images_tcg_pcom"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upgrade_pokemon_images"("max_n" integer DEFAULT 150) RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
declare r record; url text; st int; ok int := 0; miss int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for r in
    select p.id, p.image_url, p.external_ids->>'tcgdex_image' tcgdex_image from products p
    where p.game_id = 'pokemon' and p.language = 'EN' and p.kind = 'card' and (p.image_url like 'https://assets.tcgdex.net/en/%' or (p.image_url like 'https://assets.pokemon.com/%' and p.external_ids ? 'tcgdex_image'))
      and (not (p.external_ids ? 'ptcg_checked') or (p.external_ids->>'ptcg_checked') < (current_date - 30)::text)  -- misses retried monthly
    order by exists (select 1 from collection_items ci where ci.product_id = p.id) desc,
             (coalesce(nullif(substring(split_part(p.card_number,'/',1) from '^\d+$'),'')::int, 0)
               > coalesce(nullif(substring(split_part(p.card_number,'/',2) from '^\d+$'),'')::int, 99999)) desc,
             p.id
    limit max_n
  loop
    url := ptcg_image_url(coalesce(r.tcgdex_image, r.image_url));
    st := 0;
    if url is not null then
      begin select status into st from extensions.http(('HEAD', url, null, null, null)::extensions.http_request);
      exception when others then st := 0; end;
    end if;
    if st = 200 then
      update products set image_url = url, external_ids = external_ids || jsonb_build_object('ptcg_checked', current_date::text, 'tcgdex_image', coalesce(r.tcgdex_image, r.image_url)) where id = r.id;
      ok := ok + 1;
    else
      update products set external_ids = external_ids || jsonb_build_object('ptcg_checked', current_date::text) where id = r.id;
      miss := miss + 1;
    end if;
  end loop;
  return json_build_object('upgraded', ok, 'kept_original', miss);
end $_$;


ALTER FUNCTION "public"."upgrade_pokemon_images"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upgrade_pokemon_images_pcom"("max_n" integer DEFAULT 150) RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare r record; url text; st int; ok int := 0; miss int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  for r in select p.id, p.image_url from products p
           where p.game_id = 'pokemon' and p.language = 'EN' and p.kind = 'card' and p.image_url like 'https://assets.tcgdex.net/en/%'
             and p.external_ids ? 'ptcg_checked'
             and (not (p.external_ids ? 'pcom_checked') or (p.external_ids->>'pcom_checked') < (current_date - 14)::text)
           order by exists (select 1 from collection_items ci where ci.product_id = p.id) desc, p.id desc
           limit max_n loop
    url := pcom_image_url(r.image_url); st := 0;
    if url is not null then
      begin select status into st from extensions.http(('HEAD', url, null, null, null)::extensions.http_request); exception when others then st := 0; end;
    end if;
    if st = 200 then
      update products set image_url = url, external_ids = external_ids || jsonb_build_object('pcom_checked', current_date::text, 'tcgdex_image', r.image_url) where id = r.id; ok := ok + 1;
    else
      update products set external_ids = external_ids || jsonb_build_object('pcom_checked', current_date::text) where id = r.id; miss := miss + 1;
    end if;
  end loop;
  return json_build_object('upgraded', ok, 'kept', miss);
end $$;


ALTER FUNCTION "public"."upgrade_pokemon_images_pcom"("max_n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vintage_jp_check"("sid" bigint, "p_apply" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare s sets; w text; best record; renamed int := 0; ours_n int;
begin
  select * into s from sets where id = sid;
  select count(*) into ours_n from products where set_id = sid and kind = 'card';
  select content::jsonb->'parse'->>'wikitext' into w from extensions.http_get(
    'https://bulbapedia.bulbagarden.net/w/api.php?action=parse&prop=wikitext&format=json&formatversion=2&redirects=1&page='
    || extensions.urlencode(bulba_page_for(s)));
  if w is null then return jsonb_build_object('set', s.code, 'note', 'no page'); end if;

  with ours as (select row_number() over (order by card_number, id) ord, name from products where set_id = sid and kind = 'card')
  select v.seg, max(v.title) title, count(*) n,
         count(*) filter (where lower(o.name) = lower(v.nm)) same,
         count(*) filter (where o.name !~ '[ぁ-んァ-ヶ一-龯]') en_ours
    into best
    from bulba_list_entries(w) v left join ours o on o.ord = v.ord
   group by v.seg order by 4 desc, abs(count(*) - ours_n) limit 1;
  if best is null then return jsonb_build_object('set', s.code, 'note', 'no list'); end if;

  if p_apply and best.same >= 0.9 * nullif(best.en_ours, 0) then
    with ours as (select row_number() over (order by card_number, id) ord, id from products where set_id = sid and kind = 'card'),
         v as (select * from bulba_list_entries(w) where seg = best.seg)
    update products p set name_jp = coalesce(p.name_jp, p.name), name = v.nm
      from ours o join v on v.ord = o.ord
     where p.id = o.id and p.name ~ '[ぁ-んァ-ヶ一-龯]' and v.nm is not null and v.nm !~ '[ぁ-んァ-ヶ一-龯]';
    get diagnostics renamed = row_count;
  end if;

  return jsonb_build_object('set', s.code, 'table', best.title, 'official', best.n, 'ours', ours_n,
    'english_ours', best.en_ours, 'aligned', best.same, 'renamed', renamed);
end $$;


ALTER FUNCTION "public"."vintage_jp_check"("sid" bigint, "p_apply" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."_backup_fn_20261022" (
    "proname" "name",
    "def" "text"
);


ALTER TABLE "public"."_backup_fn_20261022" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."_backup_products_20261022" (
    "id" bigint,
    "game_id" "text",
    "set_id" bigint,
    "kind" "text",
    "name" "text",
    "card_number" "text",
    "rarity" "text",
    "variant" "text",
    "language" "text",
    "image_url" "text",
    "external_ids" "jsonb",
    "price_tier" "text",
    "created_at" timestamp with time zone,
    "special" "text"
);


ALTER TABLE "public"."_backup_products_20261022" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."_bulba_pages" (
    "page" "text" NOT NULL,
    "wikitext" "text",
    "fetched_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."_bulba_pages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."_merged_products" (
    "id" bigint,
    "game_id" "text",
    "set_id" bigint,
    "kind" "text",
    "name" "text",
    "card_number" "text",
    "rarity" "text",
    "variant" "text",
    "language" "text",
    "image_url" "text",
    "external_ids" "jsonb",
    "price_tier" "text",
    "created_at" timestamp with time zone,
    "special" "text",
    "merged_into" bigint,
    "merged_at" timestamp with time zone,
    "name_jp" "text"
);


ALTER TABLE "public"."_merged_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."_resync_baseline" (
    "set_id" bigint,
    "n_before" bigint,
    "at" timestamp with time zone
);


ALTER TABLE "public"."_resync_baseline" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."alert_events" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "alert_id" bigint,
    "product_id" bigint NOT NULL,
    "message" "text" NOT NULL,
    "price" numeric(12,2),
    "seen" boolean DEFAULT false NOT NULL,
    "at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."alert_events" OWNER TO "postgres";


ALTER TABLE "public"."alert_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."alert_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."api_usage" (
    "day" "date" NOT NULL,
    "source" "text" NOT NULL,
    "requests" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."api_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fx_rates" (
    "currency" "text" NOT NULL,
    "aud_per_unit" numeric(14,6) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."fx_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sold_listings" (
    "id" bigint NOT NULL,
    "product_id" bigint NOT NULL,
    "market" "text" NOT NULL,
    "condition" "text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "price" numeric(12,2) NOT NULL,
    "currency" "text" NOT NULL,
    "sold_at" timestamp with time zone NOT NULL,
    "title" "text",
    "url" "text",
    "image_url" "text",
    "ebay_item_id" "text",
    "excluded" boolean DEFAULT false NOT NULL,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "exclusion_reason" "text",
    "user_decision" "text",
    "decided_at" timestamp with time zone,
    CONSTRAINT "sold_listings_user_decision_check" CHECK (("user_decision" = ANY (ARRAY['include'::"text", 'exclude'::"text"])))
);


ALTER TABLE "public"."sold_listings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."market_price_v" WITH ("security_invoker"='on') AS
 SELECT "s"."product_id",
    "s"."market",
    "s"."condition",
    "s"."grade",
    ("percentile_cont"((0.5)::double precision) WITHIN GROUP (ORDER BY ((("s"."price" * COALESCE("f"."aud_per_unit", (1)::numeric)))::double precision)))::numeric(12,2) AS "median_aud",
    "count"(*) AS "sales"
   FROM (( SELECT "sold_listings"."id",
            "sold_listings"."product_id",
            "sold_listings"."market",
            "sold_listings"."condition",
            "sold_listings"."grade",
            "sold_listings"."price",
            "sold_listings"."currency",
            "sold_listings"."sold_at",
            "sold_listings"."title",
            "sold_listings"."url",
            "sold_listings"."image_url",
            "sold_listings"."ebay_item_id",
            "sold_listings"."excluded",
            "sold_listings"."fetched_at",
            "sold_listings"."exclusion_reason",
            "sold_listings"."user_decision",
            "sold_listings"."decided_at",
            "row_number"() OVER (PARTITION BY "sold_listings"."product_id", "sold_listings"."market", "sold_listings"."condition", "sold_listings"."grade" ORDER BY "sold_listings"."sold_at" DESC) AS "rn"
           FROM "public"."sold_listings"
          WHERE "public"."sold_is_credible"("sold_listings"."excluded", "sold_listings"."user_decision")) "s"
     LEFT JOIN "public"."fx_rates" "f" ON (("f"."currency" = "s"."currency")))
  WHERE ("s"."rn" <= 10)
  GROUP BY "s"."product_id", "s"."market", "s"."condition", "s"."grade";


ALTER VIEW "public"."market_price_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."arbitrage_v" WITH ("security_invoker"='on') AS
 SELECT "a"."product_id",
    "a"."condition",
    "a"."grade",
    "a"."median_aud" AS "au_price",
    "a"."sales" AS "au_sales",
    "o"."market" AS "other_market",
    "o"."median_aud" AS "other_price",
    "o"."sales" AS "other_sales",
    ("a"."median_aud" - "o"."median_aud") AS "gap_aud",
    "round"(((("a"."median_aud" - "o"."median_aud") / NULLIF("o"."median_aud", (0)::numeric)) * (100)::numeric), 1) AS "gap_pct"
   FROM ("public"."market_price_v" "a"
     JOIN "public"."market_price_v" "o" ON ((("o"."product_id" = "a"."product_id") AND ("o"."condition" = "a"."condition") AND ("o"."grade" = "a"."grade") AND ("o"."market" <> 'AU'::"text"))))
  WHERE (("a"."market" = 'AU'::"text") AND ("a"."sales" >= 3) AND ("o"."sales" >= 3));


ALTER VIEW "public"."arbitrage_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ask_fetch_state" (
    "qkey" "text" NOT NULL,
    "last_fetched" timestamp with time zone,
    "items" integer,
    "note" "text"
);


ALTER TABLE "public"."ask_fetch_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ask_listings" (
    "id" bigint NOT NULL,
    "product_id" bigint NOT NULL,
    "market" "text" DEFAULT 'AU'::"text" NOT NULL,
    "condition" "text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "price" numeric NOT NULL,
    "currency" "text" NOT NULL,
    "title" "text",
    "url" "text",
    "image_url" "text",
    "ebay_item_id" "text" NOT NULL,
    "excluded" boolean DEFAULT false NOT NULL,
    "exclusion_reason" "text",
    "first_seen" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ask_listings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ask_listings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ask_listings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ask_listings_id_seq" OWNED BY "public"."ask_listings"."id";



CREATE OR REPLACE VIEW "public"."ask_price_v" WITH ("security_invoker"='true') AS
 SELECT "a"."product_id",
    "a"."market",
    "a"."condition",
    "a"."grade",
    ("percentile_cont"((0.5)::double precision) WITHIN GROUP (ORDER BY ((("a"."price" * COALESCE("f"."aud_per_unit", (1)::numeric)))::double precision)))::numeric(12,2) AS "median_ask_aud",
    ("min"(("a"."price" * COALESCE("f"."aud_per_unit", (1)::numeric))))::numeric(12,2) AS "low_ask_aud",
    "count"(*) AS "listings",
    ("count"(*) >= 4) AS "enough_listings",
    "max"("a"."last_seen") AS "updated_at",
    'asking (eBay active listings)'::"text" AS "basis"
   FROM ("public"."ask_listings" "a"
     LEFT JOIN "public"."fx_rates" "f" ON (("f"."currency" = "a"."currency")))
  WHERE (NOT "a"."excluded")
  GROUP BY "a"."product_id", "a"."market", "a"."condition", "a"."grade";


ALTER VIEW "public"."ask_price_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."binder_shares" (
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "token" "text" DEFAULT "replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text") NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."binder_shares" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_items" (
    "id" bigint NOT NULL,
    "cart_id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "product_id" bigint NOT NULL,
    "side" "text" NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "unit_price" numeric(12,2),
    CONSTRAINT "cart_items_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "cart_items_side_check" CHECK (("side" = ANY (ARRAY['buy'::"text", 'sell'::"text"])))
);


ALTER TABLE "public"."cart_items" OWNER TO "postgres";


ALTER TABLE "public"."cart_items" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cart_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."carts" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "buy_discount" numeric(12,2) DEFAULT 0 NOT NULL,
    "buy_discount_mode" "text" DEFAULT '%'::"text" NOT NULL,
    "sell_discount" numeric(12,2) DEFAULT 0 NOT NULL,
    "sell_discount_mode" "text" DEFAULT '%'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    CONSTRAINT "carts_buy_discount_mode_check" CHECK (("buy_discount_mode" = ANY (ARRAY['%'::"text", '$'::"text"]))),
    CONSTRAINT "carts_sell_discount_mode_check" CHECK (("sell_discount_mode" = ANY (ARRAY['%'::"text", '$'::"text"]))),
    CONSTRAINT "carts_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."carts" OWNER TO "postgres";


ALTER TABLE "public"."carts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."carts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."catalog_cards" (
    "source" "text" NOT NULL,
    "lang" "text" NOT NULL,
    "set_code" "text",
    "id" "text" NOT NULL,
    "local_id" "text",
    "name" "text",
    "image" "text",
    "kind" "text",
    "rarity" "text"
);


ALTER TABLE "public"."catalog_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalog_exclusions" (
    "tcgdex_id" "text" NOT NULL,
    "reason" "text",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."catalog_exclusions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalog_fetch_log" (
    "source" "text" NOT NULL,
    "catalog_set" "text" NOT NULL,
    "fetched_at" timestamp with time zone DEFAULT "now"(),
    "items" integer
);


ALTER TABLE "public"."catalog_fetch_log" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."catalog_health" AS
SELECT
    NULL::"text" AS "game",
    NULL::"text" AS "code",
    NULL::"text" AS "name",
    NULL::"text" AS "language",
    NULL::"text" AS "issue",
    NULL::integer AS "n",
    NULL::"text" AS "detail";


ALTER VIEW "public"."catalog_health" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalog_health_ignore" (
    "set_id" bigint NOT NULL,
    "card_number" "text" NOT NULL,
    "reason" "text" NOT NULL
);


ALTER TABLE "public"."catalog_health_ignore" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalog_lookup_log" (
    "product_id" bigint NOT NULL,
    "looked_up_at" timestamp with time zone DEFAULT "now"(),
    "found" boolean
);


ALTER TABLE "public"."catalog_lookup_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalog_sets" (
    "source" "text" NOT NULL,
    "lang" "text" NOT NULL,
    "id" "text" NOT NULL,
    "name" "text",
    "series" "text",
    "release_date" "date",
    "code" "text"
);


ALTER TABLE "public"."catalog_sets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."collection_items" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"(),
    "product_id" bigint NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "cost_paid" numeric(12,2),
    "date_added" "date",
    "notes" "text",
    "location" "text",
    "for_sale" boolean DEFAULT false NOT NULL,
    "asking_price" numeric(12,2),
    "show_price" boolean DEFAULT true NOT NULL,
    "acquired_at" "date",
    CONSTRAINT "collection_items_asking_price_check" CHECK ((("asking_price" IS NULL) OR ("asking_price" >= (0)::numeric))),
    CONSTRAINT "collection_items_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."collection_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" bigint NOT NULL,
    "game_id" "text" NOT NULL,
    "set_id" bigint,
    "kind" "text" NOT NULL,
    "name" "text" NOT NULL,
    "card_number" "text" DEFAULT ''::"text" NOT NULL,
    "rarity" "text",
    "variant" "text" DEFAULT ''::"text" NOT NULL,
    "language" "text" DEFAULT 'EN'::"text" NOT NULL,
    "image_url" "text",
    "external_ids" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "price_tier" "text" DEFAULT 'normal'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "special" "text",
    "name_jp" "text",
    CONSTRAINT "products_kind_check" CHECK (("kind" = ANY (ARRAY['card'::"text", 'sealed'::"text"]))),
    CONSTRAINT "products_price_tier_check" CHECK (("price_tier" = ANY (ARRAY['hot'::"text", 'normal'::"text", 'quiet'::"text"])))
);


ALTER TABLE "public"."products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."series" (
    "id" bigint NOT NULL,
    "game_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "sort_order" integer,
    "logo_url" "text",
    "hidden" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."series" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."catalog_v" WITH ("security_invoker"='on') AS
 SELECT "p"."id",
    "p"."name",
    "p"."card_number",
    "p"."variant",
    "p"."language",
    "p"."kind",
    "p"."image_url",
    "p"."game_id",
    "p"."set_id",
    "p"."rarity",
    "p"."created_at",
    "s"."name" AS "set_name",
    "s"."release_date",
    "s"."series_id",
    "sr"."name" AS "series_name",
    (EXISTS ( SELECT 1
           FROM "public"."collection_items" "c"
          WHERE (("c"."product_id" = "p"."id") AND ("c"."owner_id" = "auth"."uid"())))) AS "owned",
    COALESCE("p"."special", 'Standard'::"text") AS "special",
    (NULLIF("substring"("regexp_replace"("p"."card_number", '^.*-'::"text", ''::"text"), '[0-9]+'::"text"), ''::"text"))::integer AS "card_num_int"
   FROM (("public"."products" "p"
     LEFT JOIN "public"."sets" "s" ON (("s"."id" = "p"."set_id")))
     LEFT JOIN "public"."series" "sr" ON (("sr"."id" = "s"."series_id")))
  WHERE (("p"."set_id" IS NULL) OR ("s"."id" IS NOT NULL));


ALTER VIEW "public"."catalog_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."collection_import" (
    "game_id" "text",
    "series_name" "text",
    "set_name" "text",
    "product_name" "text",
    "card_number" "text",
    "rarity" "text",
    "variant" "text",
    "language" "text",
    "kind" "text",
    "condition" "text",
    "grade" "text",
    "quantity" "text",
    "cost_paid" "text",
    "date_added" "text",
    "notes" "text"
);


ALTER TABLE "public"."collection_import" OWNER TO "postgres";


ALTER TABLE "public"."collection_items" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."collection_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dbs_official" (
    "game" "text" NOT NULL,
    "series_id" "text" NOT NULL,
    "card_id" "text" NOT NULL,
    "base_id" "text" NOT NULL,
    "name" "text"
);


ALTER TABLE "public"."dbs_official" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dbs_official_series" (
    "game" "text" NOT NULL,
    "series_id" "text" NOT NULL,
    "series_name" "text",
    "loaded_at" timestamp with time zone,
    "cards" integer
);


ALTER TABLE "public"."dbs_official_series" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ebay_auth" (
    "id" integer DEFAULT 1 NOT NULL,
    "token" "text",
    "expires_at" timestamp with time zone,
    "scope" "text"
);


ALTER TABLE "public"."ebay_auth" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."follows" (
    "follower" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "followee" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "follows_check" CHECK (("follower" <> "followee")),
    CONSTRAINT "follows_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text"])))
);


ALTER TABLE "public"."follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."games" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "logo_url" "text"
);


ALTER TABLE "public"."games" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."img_probe" (
    "product_id" bigint NOT NULL,
    "url" "text",
    "status" integer,
    "probed_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."img_probe" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."img_probe_ptcg" (
    "product_id" bigint NOT NULL,
    "url" "text",
    "status" integer,
    "probed_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."img_probe_ptcg" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."import_expect" AS
 WITH "i" AS (
         SELECT "row_number"() OVER (ORDER BY "ci"."ctid") AS "rn",
            "ci"."game_id",
            "ci"."series_name",
            "ci"."set_name",
            "ci"."product_name",
            "ci"."card_number",
            "ci"."rarity",
            "ci"."variant",
            "ci"."language",
            "ci"."kind",
            "ci"."condition",
            "ci"."grade",
            "ci"."quantity",
            "ci"."cost_paid",
            "ci"."date_added",
            "ci"."notes",
            "to_date"("ci"."date_added", 'DD/MM/YYYY'::"text") AS "d"
           FROM "public"."collection_import" "ci"
        ), "x" AS (
         SELECT "i"."rn",
            "i"."game_id",
            "i"."series_name",
            "i"."set_name",
            "i"."product_name",
            "i"."card_number",
            "i"."rarity",
            "i"."variant",
            "i"."language",
            "i"."kind",
            "i"."condition",
            "i"."grade",
            "i"."quantity",
            "i"."cost_paid",
            "i"."date_added",
            "i"."notes",
            "i"."d",
            (EXISTS ( SELECT 1
                   FROM "public"."sets" "s"
                  WHERE (("s"."game_id" = "i"."game_id") AND ("s"."language" = "i"."language") AND ("lower"("regexp_replace"("s"."name", '\s*\(JP\)$'::"text", ''::"text")) = "lower"("i"."set_name"))))) AS "own_lang_set",
            ( SELECT "min"("s"."language") AS "min"
                   FROM "public"."sets" "s"
                  WHERE (("s"."game_id" = "i"."game_id") AND ("s"."language" <> "i"."language") AND ("lower"("regexp_replace"("s"."name", '\s*\(JP\)$'::"text", ''::"text")) = "lower"("i"."set_name")))) AS "other_lang"
           FROM "i"
        )
 SELECT "rn",
    "game_id",
    "series_name",
    "set_name",
    "product_name",
    "card_number",
    "rarity",
    "variant",
    "language",
    "kind",
    "condition",
    "grade",
    "quantity",
    "cost_paid",
    "date_added",
    "notes",
    "d",
    "own_lang_set",
    "other_lang",
        CASE
            WHEN (("game_id" = 'pokemon'::"text") AND (NOT "own_lang_set") AND ("other_lang" IS NOT NULL)) THEN "other_lang"
            ELSE "language"
        END AS "exp_lang"
   FROM "x";


ALTER VIEW "public"."import_expect" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."import_plan" (
    "rn" bigint NOT NULL,
    "game_id" "text",
    "exp_lang" "text",
    "set_name" "text",
    "card_number" "text",
    "variant" "text",
    "product_name" "text",
    "d" "date",
    "condition" "text",
    "quantity" integer,
    "target_set" bigint,
    "target_product" bigint,
    "item_id" bigint,
    "current_product" bigint,
    "action" "text",
    "note" "text"
);


ALTER TABLE "public"."import_plan" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jp_logo_urls" (
    "file" "text" NOT NULL,
    "url" "text"
);


ALTER TABLE "public"."jp_logo_urls" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jp_set_logo_files" (
    "jp" "text" NOT NULL,
    "file" "text"
);


ALTER TABLE "public"."jp_set_logo_files" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jp_set_names" (
    "jp" "text" NOT NULL,
    "en" "text" NOT NULL,
    "source" "text"
);


ALTER TABLE "public"."jp_set_names" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."listings" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "product_id" bigint NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "quantity" integer NOT NULL,
    "price" numeric(12,2),
    "mode" "text" DEFAULT 'sale'::"text" NOT NULL,
    "note" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "photos" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    CONSTRAINT "listings_mode_check" CHECK (("mode" = ANY (ARRAY['sale'::"text", 'trade'::"text", 'either'::"text"]))),
    CONSTRAINT "listings_note_check" CHECK (("length"("note") <= 280)),
    CONSTRAINT "listings_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "listings_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "listings_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'sold'::"text", 'withdrawn'::"text"])))
);


ALTER TABLE "public"."listings" OWNER TO "postgres";


ALTER TABLE "public"."listings" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."listings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."news_feeds" (
    "game_id" "text",
    "source" "text",
    "url" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "last_ok" timestamp with time zone,
    "last_error" "text"
);


ALTER TABLE "public"."news_feeds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_items" (
    "id" bigint NOT NULL,
    "game_id" "text",
    "source" "text",
    "title" "text" NOT NULL,
    "url" "text" NOT NULL,
    "published_at" timestamp with time zone,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."news_items" OWNER TO "postgres";


ALTER TABLE "public"."news_items" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."news_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."offer_messages" (
    "id" bigint NOT NULL,
    "offer_id" bigint NOT NULL,
    "sender_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "offer_messages_body_check" CHECK ((("length"("body") >= 1) AND ("length"("body") <= 1000)))
);


ALTER TABLE "public"."offer_messages" OWNER TO "postgres";


ALTER TABLE "public"."offer_messages" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."offer_messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."offers" (
    "id" bigint NOT NULL,
    "listing_id" bigint NOT NULL,
    "buyer_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "seller_id" "uuid" NOT NULL,
    "quantity" integer NOT NULL,
    "price" numeric(12,2),
    "message" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "offers_message_check" CHECK (("length"("message") <= 500)),
    CONSTRAINT "offers_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "offers_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "offers_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text", 'withdrawn'::"text", 'sent'::"text", 'received'::"text"])))
);


ALTER TABLE "public"."offers" OWNER TO "postgres";


ALTER TABLE "public"."offers" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."offers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."op_logo" (
    "code" "text" NOT NULL,
    "page" "text",
    "logo" "text",
    "probed_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."op_logo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."op_official" (
    "series_id" "text" NOT NULL,
    "series_name" "text",
    "card_id" "text" NOT NULL,
    "base_id" "text" NOT NULL,
    "name" "text"
);


ALTER TABLE "public"."op_official" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."op_official_series" (
    "series_id" "text" NOT NULL,
    "name" "text"
);


ALTER TABLE "public"."op_official_series" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pcom_expansions" (
    "set_id" bigint NOT NULL,
    "page_slug" "text",
    "img_slug" "text",
    "code" "text",
    "checked_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "note" "text"
);


ALTER TABLE "public"."pcom_expansions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pokemon_species_names" (
    "dex" integer NOT NULL,
    "name_en" "text" NOT NULL,
    "name_ja" "text" NOT NULL
);


ALTER TABLE "public"."pokemon_species_names" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."portfolio_snapshots" (
    "owner_id" "uuid" NOT NULL,
    "day" "date" NOT NULL,
    "set_id" bigint NOT NULL,
    "game_id" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "language" "text" NOT NULL,
    "items" integer NOT NULL,
    "value" numeric(14,2) DEFAULT 0 NOT NULL,
    "priced_items" integer DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'daily'::"text" NOT NULL
);


ALTER TABLE "public"."portfolio_snapshots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_alerts" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "product_id" bigint NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "kind" "text" NOT NULL,
    "threshold" numeric(12,2) NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "last_triggered_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "price_alerts_kind_check" CHECK (("kind" = ANY (ARRAY['below'::"text", 'above'::"text", 'move'::"text"]))),
    CONSTRAINT "price_alerts_threshold_check" CHECK (("threshold" > (0)::numeric))
);


ALTER TABLE "public"."price_alerts" OWNER TO "postgres";


ALTER TABLE "public"."price_alerts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."price_alerts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."price_v" WITH ("security_invoker"='on') AS
 SELECT "product_id",
    "condition",
    "grade",
    ("percentile_cont"((0.5)::double precision) WITHIN GROUP (ORDER BY (("price")::double precision)))::numeric(12,2) AS "median",
    "count"(*) AS "sales",
    "max"("sold_at") AS "last_sold"
   FROM ( SELECT "sold_listings"."id",
            "sold_listings"."product_id",
            "sold_listings"."market",
            "sold_listings"."condition",
            "sold_listings"."grade",
            "sold_listings"."price",
            "sold_listings"."currency",
            "sold_listings"."sold_at",
            "sold_listings"."title",
            "sold_listings"."url",
            "sold_listings"."image_url",
            "sold_listings"."ebay_item_id",
            "sold_listings"."excluded",
            "sold_listings"."fetched_at",
            "sold_listings"."exclusion_reason",
            "sold_listings"."user_decision",
            "sold_listings"."decided_at",
            "row_number"() OVER (PARTITION BY "sold_listings"."product_id", "sold_listings"."condition", "sold_listings"."grade" ORDER BY "sold_listings"."sold_at" DESC) AS "rn"
           FROM "public"."sold_listings"
          WHERE (("sold_listings"."market" = 'AU'::"text") AND "public"."sold_is_credible"("sold_listings"."excluded", "sold_listings"."user_decision"))) "x"
  WHERE ("rn" <= 10)
  GROUP BY "product_id", "condition", "grade";


ALTER VIEW "public"."price_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."product_tcgp_keys" AS
 SELECT "p"."id",
    "p"."set_id",
    "p"."name",
    "p"."card_number",
    "p"."variant",
    "public"."tcgp_num"("p"."card_number") AS "num",
    "k"."sub_type",
    "k"."pattern"
   FROM ("public"."products" "p"
     JOIN "public"."sets" "s" ON (("s"."id" = "p"."set_id"))),
    LATERAL "public"."tcgp_variant_key"("p"."variant") "k"("sub_type", "pattern")
  WHERE (("p"."kind" = 'card'::"text") AND ("p"."game_id" = 'pokemon'::"text") AND ("s"."language" = 'EN'::"text"));


ALTER VIEW "public"."product_tcgp_keys" OWNER TO "postgres";


ALTER TABLE "public"."products" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."products_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."profile_contacts" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "contact" "text",
    CONSTRAINT "profile_contacts_contact_check" CHECK (("length"("contact") <= 200))
);


ALTER TABLE "public"."profile_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "handle" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "kind" "text" DEFAULT 'person'::"text" NOT NULL,
    "bio" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vendor_page_on" boolean DEFAULT false NOT NULL,
    CONSTRAINT "profiles_bio_check" CHECK (("length"("bio") <= 280)),
    CONSTRAINT "profiles_display_name_check" CHECK ((("length"("display_name") >= 1) AND ("length"("display_name") <= 60))),
    CONSTRAINT "profiles_handle_check" CHECK (("handle" ~ '^[a-z0-9_]{3,20}$'::"text")),
    CONSTRAINT "profiles_kind_check" CHECK (("kind" = ANY (ARRAY['person'::"text", 'organisation'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ptcg_alt" (
    "set_code" "text" NOT NULL,
    "ptcg_id" "text" NOT NULL
);


ALTER TABLE "public"."ptcg_alt" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scan_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "image_ref" "text",
    "ximilar_result" "jsonb",
    "chosen_catalog_id" bigint,
    "confidence" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."scan_log" OWNER TO "postgres";


ALTER TABLE "public"."scan_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."scan_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."series" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."series_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE MATERIALIZED VIEW "public"."set_card_totals" AS
 SELECT "p"."set_id",
    ("count"(*))::integer AS "total"
   FROM ("public"."products" "p"
     JOIN "public"."sets" "s" ON ((("s"."id" = "p"."set_id") AND (NOT "s"."hidden"))))
  WHERE ("p"."kind" = 'card'::"text")
  GROUP BY "p"."set_id"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."set_card_totals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."set_checklist" (
    "set_id" bigint NOT NULL,
    "card_number" "text" NOT NULL,
    "name" "text",
    "seen_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."set_checklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."set_checklist_runs" (
    "set_id" bigint NOT NULL,
    "page" "text",
    "checked_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "n" integer,
    "note" "text"
);


ALTER TABLE "public"."set_checklist_runs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."set_checklist_current" WITH ("security_invoker"='true') AS
 SELECT "c"."set_id",
    "c"."card_number",
    "c"."name"
   FROM ("public"."set_checklist" "c"
     JOIN "public"."set_checklist_runs" "r" USING ("set_id"))
  WHERE ("c"."seen_at" >= "r"."checked_at");


ALTER VIEW "public"."set_checklist_current" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."set_count_check" (
    "set_id" bigint NOT NULL,
    "game_id" "text",
    "source" "text",
    "expected" integer,
    "ours" integer,
    "checked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."set_count_check" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."set_links" (
    "set_id" bigint NOT NULL,
    "source" "text" NOT NULL,
    "catalog_set" "text" NOT NULL
);


ALTER TABLE "public"."set_links" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."set_ratio_v" WITH ("security_invoker"='on') AS
 WITH "card_vals" AS (
         SELECT "p"."set_id",
            "count"(*) AS "cards_total",
            "count"("pr"."median") AS "cards_priced",
            "sum"("pr"."median") AS "cards_value"
           FROM ("public"."products" "p"
             LEFT JOIN "public"."price_v" "pr" ON ((("pr"."product_id" = "p"."id") AND ("pr"."condition" = 'NM'::"text") AND ("pr"."grade" = ''::"text"))))
          WHERE ("p"."kind" = 'card'::"text")
          GROUP BY "p"."set_id"
        ), "box" AS (
         SELECT DISTINCT ON ("p"."set_id") "p"."set_id",
            "p"."id" AS "box_id",
            "p"."name" AS "box_name",
            COALESCE("pr"."median", "ps"."median") AS "box_price",
            COALESCE("pr"."sales", "ps"."sales") AS "box_sales"
           FROM (("public"."products" "p"
             LEFT JOIN "public"."price_v" "pr" ON ((("pr"."product_id" = "p"."id") AND ("pr"."condition" = 'NM'::"text") AND ("pr"."grade" = ''::"text"))))
             LEFT JOIN "public"."price_v" "ps" ON ((("ps"."product_id" = "p"."id") AND ("ps"."condition" = 'Sealed'::"text") AND ("ps"."grade" = ''::"text"))))
          WHERE (("p"."kind" = 'sealed'::"text") AND ("p"."name" ~* 'booster box'::"text") AND ("p"."name" !~* '(case|half|mini|\mx[0-9])'::"text"))
          ORDER BY "p"."set_id", (COALESCE("pr"."median", "ps"."median") IS NULL), COALESCE("pr"."sales", "ps"."sales") DESC NULLS LAST, "p"."id"
        )
 SELECT "s"."id" AS "set_id",
    "s"."name" AS "set_name",
    "s"."game_id",
    "s"."language",
    "s"."series_id",
    "s"."release_date",
    "cv"."cards_total",
    "cv"."cards_priced",
    "cv"."cards_value",
    "b"."box_id",
    "b"."box_name",
    "b"."box_price",
    "b"."box_sales",
        CASE
            WHEN (("b"."box_price" > (0)::numeric) AND ("cv"."cards_value" IS NOT NULL)) THEN "round"(("cv"."cards_value" / "b"."box_price"), 2)
            ELSE NULL::numeric
        END AS "ratio"
   FROM (("public"."sets" "s"
     JOIN "card_vals" "cv" ON (("cv"."set_id" = "s"."id")))
     JOIN "box" "b" ON (("b"."set_id" = "s"."id")));


ALTER VIEW "public"."set_ratio_v" OWNER TO "postgres";


ALTER TABLE "public"."sets" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."sets_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."sold_listings" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."sold_listings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."sold_review_v" WITH ("security_invoker"='on') AS
 SELECT "id",
    "product_id",
    "market",
    "condition",
    "grade",
    "price",
    "currency",
    "sold_at",
    "title",
    "url",
    "image_url",
    "excluded",
    "exclusion_reason",
    "user_decision",
    "public"."sold_is_credible"("excluded", "user_decision") AS "credible",
    "row_number"() OVER (PARTITION BY "product_id", "market", "condition", "grade", ("public"."sold_is_credible"("excluded", "user_decision")) ORDER BY "sold_at" DESC) AS "recency"
   FROM "public"."sold_listings";


ALTER VIEW "public"."sold_review_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_log" (
    "id" bigint NOT NULL,
    "at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "set_id" bigint,
    "game_id" "text",
    "items" integer,
    "note" "text"
);


ALTER TABLE "public"."sync_log" OWNER TO "postgres";


ALTER TABLE "public"."sync_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."sync_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tcgp_groups" (
    "category_id" integer NOT NULL,
    "group_id" integer NOT NULL,
    "name" "text",
    "abbreviation" "text",
    "published" "date",
    "set_id" bigint,
    "loaded_at" timestamp with time zone,
    "printings" integer
);


ALTER TABLE "public"."tcgp_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tcgp_printings" (
    "group_id" integer NOT NULL,
    "product_id" integer NOT NULL,
    "sub_type" "text" NOT NULL,
    "name" "text",
    "number" "text",
    "rarity" "text",
    "image_url" "text",
    "market" numeric,
    "seen_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tcgp_printings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."tcgp_keys" AS
 SELECT "g"."set_id",
    "p"."group_id",
    "p"."product_id",
    "p"."name",
    "p"."number",
    "p"."rarity",
        CASE
            WHEN ("x"."pat" <> ''::"text") THEN 'Reverse Holofoil'::"text"
            ELSE "p"."sub_type"
        END AS "sub_type",
    "p"."image_url",
    "p"."market",
    "public"."tcgp_num"("p"."number") AS "num",
    "x"."pat" AS "pattern"
   FROM ("public"."tcgp_printings" "p"
     JOIN "public"."tcgp_groups" "g" USING ("group_id")),
    LATERAL ( SELECT
                CASE
                    WHEN (("p"."name" ~* '\((([a-z]+ )?ball( pattern)?|energy symbol pattern|team rocket)\)\s*$'::"text") AND ("p"."sub_type" = ANY (ARRAY['Reverse Holofoil'::"text", 'Holofoil'::"text"]))) THEN "public"."tcgp_pattern"("substring"("p"."name", '\(([^)]*)\)\s*$'::"text"))
                    ELSE ''::"text"
                END AS "pat") "x"
  WHERE (("g"."set_id" IS NOT NULL) AND ("p"."seen_at" >= "g"."loaded_at"));


ALTER VIEW "public"."tcgp_keys" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tcgp_reconcile_log" (
    "id" bigint NOT NULL,
    "run_id" "uuid",
    "applied" boolean,
    "set_id" bigint,
    "action" "text",
    "product_id" bigint,
    "detail" "text",
    "at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tcgp_reconcile_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."tcgp_reconcile_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."tcgp_reconcile_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."tcgp_reconcile_log_id_seq" OWNED BY "public"."tcgp_reconcile_log"."id";



CREATE OR REPLACE VIEW "public"."tcgp_set_fit" AS
 SELECT "id" AS "set_id",
    "name",
    ( SELECT "count"(DISTINCT "o"."num") AS "count"
           FROM "public"."product_tcgp_keys" "o"
          WHERE ("o"."set_id" = "s"."id")) AS "our_nums",
    ( SELECT "count"(DISTINCT "o"."num") AS "count"
           FROM "public"."product_tcgp_keys" "o"
          WHERE (("o"."set_id" = "s"."id") AND (EXISTS ( SELECT 1
                   FROM "public"."tcgp_keys" "t"
                  WHERE (("t"."set_id" = "s"."id") AND ("t"."num" = "o"."num")))))) AS "matched_nums",
    ( SELECT "count"(DISTINCT "t"."num") AS "count"
           FROM "public"."tcgp_keys" "t"
          WHERE ("t"."set_id" = "s"."id")) AS "tcgp_nums",
    (EXISTS ( SELECT 1
           FROM "public"."tcgp_keys" "t"
          WHERE (("t"."set_id" = "s"."id") AND ("t"."sub_type" <> ALL (ARRAY['Normal'::"text", 'Holofoil'::"text", 'Reverse Holofoil'::"text"]))))) AS "odd_subtypes",
    (("name" ~* 'promo|misc|classic|battle academy|energ|world championship|trainer kit|jumbo|black star|nintendo|best of|pop series|futsal|mcdonald|sample|alternate|w promotional|products|collection'::"text") OR ("code" ~ '^ecard'::"text")) AS "excluded_name"
   FROM "public"."sets" "s"
  WHERE (("language" = 'EN'::"text") AND ("game_id" = 'pokemon'::"text") AND (EXISTS ( SELECT 1
           FROM "public"."tcgp_keys" "t"
          WHERE ("t"."set_id" = "s"."id"))));


ALTER VIEW "public"."tcgp_set_fit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trade_ledger" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "product_id" bigint NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "grade" "text" DEFAULT ''::"text" NOT NULL,
    "direction" "text" NOT NULL,
    "quantity" integer NOT NULL,
    "unit_price" numeric(12,2),
    "unit_cost" numeric(12,2),
    "source" "text" NOT NULL,
    "ref_id" bigint,
    "at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trade_ledger_direction_check" CHECK (("direction" = ANY (ARRAY['in'::"text", 'out'::"text"]))),
    CONSTRAINT "trade_ledger_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."trade_ledger" OWNER TO "postgres";


ALTER TABLE "public"."trade_ledger" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."trade_ledger_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."trade_proposals" (
    "id" bigint NOT NULL,
    "from_user" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "to_user" "uuid" NOT NULL,
    "offered_items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "requested_items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "message" "text",
    "status" "text" DEFAULT 'proposed'::"text" NOT NULL,
    "from_done" boolean DEFAULT false NOT NULL,
    "to_done" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trade_proposals_check" CHECK (("from_user" <> "to_user")),
    CONSTRAINT "trade_proposals_message_check" CHECK (("length"("message") <= 500)),
    CONSTRAINT "trade_proposals_status_check" CHECK (("status" = ANY (ARRAY['proposed'::"text", 'accepted'::"text", 'declined'::"text", 'withdrawn'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."trade_proposals" OWNER TO "postgres";


ALTER TABLE "public"."trade_proposals" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."trade_proposals_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."trade_ratings" (
    "id" bigint NOT NULL,
    "offer_id" bigint NOT NULL,
    "rater_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "ratee_id" "uuid" NOT NULL,
    "stars" integer NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trade_ratings_comment_check" CHECK (("length"("comment") <= 300)),
    CONSTRAINT "trade_ratings_stars_check" CHECK ((("stars" >= 1) AND ("stars" <= 5)))
);


ALTER TABLE "public"."trade_ratings" OWNER TO "postgres";


ALTER TABLE "public"."trade_ratings" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."trade_ratings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."upcoming_sets" (
    "id" bigint NOT NULL,
    "game_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "code" "text",
    "release_date" "date",
    "date_note" "text",
    "sentiment" "text" NOT NULL,
    "summary" "text" NOT NULL,
    "signals" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "sources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "keywords" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "reviewed_on" "date" DEFAULT CURRENT_DATE NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."upcoming_sets" OWNER TO "postgres";


ALTER TABLE "public"."upcoming_sets" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."upcoming_sets_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."variant_audit" (
    "product_id" bigint NOT NULL,
    "tcgdex_id" "text",
    "set_code" "text",
    "card_number" "text",
    "name" "text",
    "our_variant" "text",
    "verdict" "text",
    "new_label" "text",
    "owned" integer,
    "checked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."variant_audit" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."variant_audit_candidates" WITH ("security_invoker"='true') AS
 WITH "sus" AS (
         SELECT ("p"."external_ids" ->> 'tcgdex'::"text") AS "tid",
            "s"."language"
           FROM (("public"."products" "p"
             JOIN "public"."sets" "s" ON (("s"."id" = "p"."set_id")))
             JOIN "public"."series" "r" ON (("r"."id" = "s"."series_id")))
          WHERE (("s"."game_id" = 'pokemon'::"text") AND ("p"."kind" = 'card'::"text") AND ("p"."external_ids" ? 'tcgdex'::"text") AND (("r"."name" ~~* 'Mega Evolution%'::"text") OR (("p"."rarity" = ANY (ARRAY['Common'::"text", 'Uncommon'::"text"])) AND ("p"."variant" = 'Holofoil'::"text")) OR (("p"."rarity" = 'Rare'::"text") AND ("p"."variant" = 'Normal'::"text") AND ("s"."release_date" >= '2023-03-01'::"date")) OR (("p"."variant" ~~ 'Reverse%'::"text") AND ("p"."rarity" ~* '(double rare|ultra rare|illustration|hyper|secret|ace spec|shiny|art rare|super rare|special art)'::"text"))))
        )
 SELECT DISTINCT "tid",
        CASE
            WHEN ("language" = 'JP'::"text") THEN 'ja'::"text"
            ELSE 'en'::"text"
        END AS "lang"
   FROM "sus";


ALTER VIEW "public"."variant_audit_candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wants" (
    "id" bigint NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "product_id" bigint NOT NULL,
    "condition" "text" DEFAULT 'NM'::"text" NOT NULL,
    "max_price" numeric(12,2),
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "language" "text" DEFAULT 'EN'::"text" NOT NULL,
    "condition_min" "text" DEFAULT 'NM'::"text" NOT NULL,
    CONSTRAINT "wants_condition_min_check" CHECK (("condition_min" = ANY (ARRAY['NM'::"text", 'LP'::"text", 'MP'::"text", 'HP'::"text", 'DMG'::"text"]))),
    CONSTRAINT "wants_language_check" CHECK (("language" = ANY (ARRAY['EN'::"text", 'JP'::"text"]))),
    CONSTRAINT "wants_note_check" CHECK (("length"("note") <= 200))
);


ALTER TABLE "public"."wants" OWNER TO "postgres";


ALTER TABLE "public"."wants" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."wants_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."ask_listings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ask_listings_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."tcgp_reconcile_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."tcgp_reconcile_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."_bulba_pages"
    ADD CONSTRAINT "_bulba_pages_pkey" PRIMARY KEY ("page");



ALTER TABLE ONLY "public"."alert_events"
    ADD CONSTRAINT "alert_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."api_usage"
    ADD CONSTRAINT "api_usage_pkey" PRIMARY KEY ("day", "source");



ALTER TABLE ONLY "public"."ask_fetch_state"
    ADD CONSTRAINT "ask_fetch_state_pkey" PRIMARY KEY ("qkey");



ALTER TABLE ONLY "public"."ask_listings"
    ADD CONSTRAINT "ask_listings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ask_listings"
    ADD CONSTRAINT "ask_listings_product_id_ebay_item_id_key" UNIQUE ("product_id", "ebay_item_id");



ALTER TABLE ONLY "public"."binder_shares"
    ADD CONSTRAINT "binder_shares_pkey" PRIMARY KEY ("owner_id");



ALTER TABLE ONLY "public"."binder_shares"
    ADD CONSTRAINT "binder_shares_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_cart_id_product_id_side_condition_grade_key" UNIQUE ("cart_id", "product_id", "side", "condition", "grade");



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."carts"
    ADD CONSTRAINT "carts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalog_cards"
    ADD CONSTRAINT "catalog_cards_pkey" PRIMARY KEY ("source", "lang", "id");



ALTER TABLE ONLY "public"."catalog_exclusions"
    ADD CONSTRAINT "catalog_exclusions_pkey" PRIMARY KEY ("tcgdex_id");



ALTER TABLE ONLY "public"."catalog_fetch_log"
    ADD CONSTRAINT "catalog_fetch_log_pkey" PRIMARY KEY ("source", "catalog_set");



ALTER TABLE ONLY "public"."catalog_health_ignore"
    ADD CONSTRAINT "catalog_health_ignore_pkey" PRIMARY KEY ("set_id", "card_number");



ALTER TABLE ONLY "public"."catalog_lookup_log"
    ADD CONSTRAINT "catalog_lookup_log_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."catalog_sets"
    ADD CONSTRAINT "catalog_sets_pkey" PRIMARY KEY ("source", "lang", "id");



ALTER TABLE ONLY "public"."collection_items"
    ADD CONSTRAINT "collection_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dbs_official"
    ADD CONSTRAINT "dbs_official_pkey" PRIMARY KEY ("game", "series_id", "card_id");



ALTER TABLE ONLY "public"."dbs_official_series"
    ADD CONSTRAINT "dbs_official_series_pkey" PRIMARY KEY ("game", "series_id");



ALTER TABLE ONLY "public"."ebay_auth"
    ADD CONSTRAINT "ebay_auth_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_pkey" PRIMARY KEY ("follower", "followee");



ALTER TABLE ONLY "public"."fx_rates"
    ADD CONSTRAINT "fx_rates_pkey" PRIMARY KEY ("currency");



ALTER TABLE ONLY "public"."games"
    ADD CONSTRAINT "games_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."img_probe"
    ADD CONSTRAINT "img_probe_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."img_probe_ptcg"
    ADD CONSTRAINT "img_probe_ptcg_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."import_plan"
    ADD CONSTRAINT "import_plan_pkey" PRIMARY KEY ("rn");



ALTER TABLE ONLY "public"."jp_logo_urls"
    ADD CONSTRAINT "jp_logo_urls_pkey" PRIMARY KEY ("file");



ALTER TABLE ONLY "public"."jp_set_logo_files"
    ADD CONSTRAINT "jp_set_logo_files_pkey" PRIMARY KEY ("jp");



ALTER TABLE ONLY "public"."jp_set_names"
    ADD CONSTRAINT "jp_set_names_pkey" PRIMARY KEY ("jp");



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_feeds"
    ADD CONSTRAINT "news_feeds_pkey" PRIMARY KEY ("url");



ALTER TABLE ONLY "public"."news_items"
    ADD CONSTRAINT "news_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_items"
    ADD CONSTRAINT "news_items_url_key" UNIQUE ("url");



ALTER TABLE ONLY "public"."offer_messages"
    ADD CONSTRAINT "offer_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."offers"
    ADD CONSTRAINT "offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."op_logo"
    ADD CONSTRAINT "op_logo_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."op_official"
    ADD CONSTRAINT "op_official_pkey" PRIMARY KEY ("series_id", "card_id");



ALTER TABLE ONLY "public"."op_official_series"
    ADD CONSTRAINT "op_official_series_pkey" PRIMARY KEY ("series_id");



ALTER TABLE ONLY "public"."pcom_expansions"
    ADD CONSTRAINT "pcom_expansions_pkey" PRIMARY KEY ("set_id");



ALTER TABLE ONLY "public"."pokemon_species_names"
    ADD CONSTRAINT "pokemon_species_names_pkey" PRIMARY KEY ("dex");



ALTER TABLE ONLY "public"."portfolio_snapshots"
    ADD CONSTRAINT "portfolio_snapshots_pkey" PRIMARY KEY ("owner_id", "day", "set_id", "kind", "language");



ALTER TABLE ONLY "public"."price_alerts"
    ADD CONSTRAINT "price_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_game_id_set_id_name_card_number_variant_language_key" UNIQUE ("game_id", "set_id", "name", "card_number", "variant", "language");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_contacts"
    ADD CONSTRAINT "profile_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_handle_key" UNIQUE ("handle");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ptcg_alt"
    ADD CONSTRAINT "ptcg_alt_pkey" PRIMARY KEY ("set_code");



ALTER TABLE ONLY "public"."scan_log"
    ADD CONSTRAINT "scan_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."series"
    ADD CONSTRAINT "series_game_id_name_key" UNIQUE ("game_id", "name");



ALTER TABLE ONLY "public"."series"
    ADD CONSTRAINT "series_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."set_checklist"
    ADD CONSTRAINT "set_checklist_pkey" PRIMARY KEY ("set_id", "card_number");



ALTER TABLE ONLY "public"."set_checklist_runs"
    ADD CONSTRAINT "set_checklist_runs_pkey" PRIMARY KEY ("set_id");



ALTER TABLE ONLY "public"."set_count_check"
    ADD CONSTRAINT "set_count_check_pkey" PRIMARY KEY ("set_id");



ALTER TABLE ONLY "public"."set_links"
    ADD CONSTRAINT "set_links_pkey" PRIMARY KEY ("set_id", "source", "catalog_set");



ALTER TABLE ONLY "public"."sets"
    ADD CONSTRAINT "sets_game_id_name_key" UNIQUE ("game_id", "name");



ALTER TABLE ONLY "public"."sets"
    ADD CONSTRAINT "sets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sold_listings"
    ADD CONSTRAINT "sold_listings_ebay_item_id_key" UNIQUE ("ebay_item_id");



ALTER TABLE ONLY "public"."sold_listings"
    ADD CONSTRAINT "sold_listings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_log"
    ADD CONSTRAINT "sync_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tcgp_groups"
    ADD CONSTRAINT "tcgp_groups_pkey" PRIMARY KEY ("group_id");



ALTER TABLE ONLY "public"."tcgp_printings"
    ADD CONSTRAINT "tcgp_printings_pkey" PRIMARY KEY ("group_id", "product_id", "sub_type");



ALTER TABLE ONLY "public"."tcgp_reconcile_log"
    ADD CONSTRAINT "tcgp_reconcile_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_ledger"
    ADD CONSTRAINT "trade_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_proposals"
    ADD CONSTRAINT "trade_proposals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_ratings"
    ADD CONSTRAINT "trade_ratings_offer_id_rater_id_key" UNIQUE ("offer_id", "rater_id");



ALTER TABLE ONLY "public"."trade_ratings"
    ADD CONSTRAINT "trade_ratings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."upcoming_sets"
    ADD CONSTRAINT "upcoming_sets_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."upcoming_sets"
    ADD CONSTRAINT "upcoming_sets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."variant_audit"
    ADD CONSTRAINT "variant_audit_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."wants"
    ADD CONSTRAINT "wants_owner_id_product_id_condition_key" UNIQUE ("owner_id", "product_id", "condition");



ALTER TABLE ONLY "public"."wants"
    ADD CONSTRAINT "wants_pkey" PRIMARY KEY ("id");



CREATE INDEX "alert_events_alert_id_idx" ON "public"."alert_events" USING "btree" ("alert_id");



CREATE INDEX "alert_events_owner_id_idx" ON "public"."alert_events" USING "btree" ("owner_id");



CREATE INDEX "alert_events_product_id_idx" ON "public"."alert_events" USING "btree" ("product_id");



CREATE INDEX "ask_listings_grp" ON "public"."ask_listings" USING "btree" ("product_id", "market", "condition", "grade");



CREATE INDEX "cart_items_owner_id_idx" ON "public"."cart_items" USING "btree" ("owner_id");



CREATE INDEX "cart_items_product_id_idx" ON "public"."cart_items" USING "btree" ("product_id");



CREATE INDEX "carts_owner_id_idx" ON "public"."carts" USING "btree" ("owner_id");



CREATE INDEX "collection_for_sale" ON "public"."collection_items" USING "btree" ("owner_id") WHERE "for_sale";



CREATE INDEX "collection_items_product_id_idx" ON "public"."collection_items" USING "btree" ("product_id");



CREATE INDEX "collection_owner_product" ON "public"."collection_items" USING "btree" ("owner_id", "product_id");



CREATE INDEX "follows_followee_idx" ON "public"."follows" USING "btree" ("followee");



CREATE INDEX "listings_owner_id_idx" ON "public"."listings" USING "btree" ("owner_id");



CREATE INDEX "listings_product_id_idx" ON "public"."listings" USING "btree" ("product_id");



CREATE INDEX "offer_messages_offer_id_idx" ON "public"."offer_messages" USING "btree" ("offer_id");



CREATE INDEX "offer_messages_sender_id_idx" ON "public"."offer_messages" USING "btree" ("sender_id");



CREATE INDEX "offers_buyer_id_idx" ON "public"."offers" USING "btree" ("buyer_id");



CREATE INDEX "offers_listing_id_idx" ON "public"."offers" USING "btree" ("listing_id");



CREATE INDEX "offers_seller_id_idx" ON "public"."offers" USING "btree" ("seller_id");



CREATE INDEX "price_alerts_owner_id_idx" ON "public"."price_alerts" USING "btree" ("owner_id");



CREATE INDEX "price_alerts_product_id_idx" ON "public"."price_alerts" USING "btree" ("product_id");



CREATE INDEX "products_name_trgm" ON "public"."products" USING "gin" ("lower"("name") "extensions"."gin_trgm_ops");



CREATE INDEX "products_numkey_idx" ON "public"."products" USING "btree" ("public"."num_key"("card_number"));



CREATE INDEX "products_search" ON "public"."products" USING "gin" ("to_tsvector"('"simple"'::"regconfig", (("name" || ' '::"text") || "card_number")));



CREATE INDEX "products_set_id_idx" ON "public"."products" USING "btree" ("set_id");



CREATE INDEX "products_special_idx" ON "public"."products" USING "btree" ("special");



CREATE INDEX "scan_log_chosen_catalog_id_idx" ON "public"."scan_log" USING "btree" ("chosen_catalog_id");



CREATE INDEX "scan_log_user_id_idx" ON "public"."scan_log" USING "btree" ("user_id");



CREATE UNIQUE INDEX "set_card_totals_pk" ON "public"."set_card_totals" USING "btree" ("set_id");



CREATE INDEX "sets_series_id_idx" ON "public"."sets" USING "btree" ("series_id");



CREATE INDEX "sold_lookup" ON "public"."sold_listings" USING "btree" ("product_id", "market", "condition", "grade", "sold_at" DESC);



CREATE INDEX "tcgp_groups_set_idx" ON "public"."tcgp_groups" USING "btree" ("set_id");



CREATE INDEX "tcgp_reconcile_log_run_idx" ON "public"."tcgp_reconcile_log" USING "btree" ("run_id");



CREATE INDEX "trade_ledger_owner_id_idx" ON "public"."trade_ledger" USING "btree" ("owner_id");



CREATE INDEX "trade_ledger_product_id_idx" ON "public"."trade_ledger" USING "btree" ("product_id");



CREATE INDEX "trade_proposals_from_user_idx" ON "public"."trade_proposals" USING "btree" ("from_user");



CREATE INDEX "trade_proposals_to_user_idx" ON "public"."trade_proposals" USING "btree" ("to_user");



CREATE INDEX "trade_ratings_ratee_id_idx" ON "public"."trade_ratings" USING "btree" ("ratee_id");



CREATE INDEX "trade_ratings_rater_id_idx" ON "public"."trade_ratings" USING "btree" ("rater_id");



CREATE INDEX "wants_product_id_idx" ON "public"."wants" USING "btree" ("product_id");



CREATE OR REPLACE VIEW "public"."catalog_health" WITH ("security_invoker"='true') AS
 SELECT 'pokemon'::"text" AS "game",
    "s"."code",
    "s"."name",
    "s"."language",
    'missing from official checklist'::"text" AS "issue",
    ("count"(*))::integer AS "n",
    "string_agg"("c"."card_number", ', '::"text" ORDER BY "c"."card_number") AS "detail"
   FROM ("public"."set_checklist_current" "c"
     JOIN "public"."sets" "s" ON (("s"."id" = "c"."set_id")))
  WHERE (("s"."release_date" >= '2004-01-01'::"date") AND (NOT COALESCE("s"."hidden", false)) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."products" "p"
          WHERE (("p"."set_id" = "c"."set_id") AND ("public"."card_key"("p"."card_number") = "public"."card_key"("c"."card_number")))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."catalog_health_ignore" "i"
          WHERE (("i"."set_id" = "c"."set_id") AND ("i"."card_number" = "c"."card_number"))))))
  GROUP BY "s"."id"
UNION ALL
 SELECT "k"."game_id" AS "game",
    "s"."code",
    "s"."name",
    "s"."language",
    ('fewer cards than '::"text" || "k"."source") AS "issue",
    ("k"."expected" - "k"."ours") AS "n",
    (("k"."ours" || ' of '::"text") || "k"."expected") AS "detail"
   FROM ("public"."set_count_check" "k"
     JOIN "public"."sets" "s" ON (("s"."id" = "k"."set_id")))
  WHERE (("k"."ours" < "k"."expected") AND (NOT COALESCE("s"."hidden", false)))
UNION ALL
 SELECT 'pokemon'::"text" AS "game",
    "a"."set_code" AS "code",
    NULL::"text" AS "name",
    NULL::"text" AS "language",
    'unverified variant'::"text" AS "issue",
    ("count"(*))::integer AS "n",
    "string_agg"((("a"."card_number" || ' '::"text") || "a"."our_variant"), ', '::"text") AS "detail"
   FROM "public"."variant_audit" "a"
  WHERE ("a"."verdict" = 'unverified'::"text")
  GROUP BY "a"."set_code";



CREATE OR REPLACE TRIGGER "listings_check" BEFORE INSERT OR UPDATE ON "public"."listings" FOR EACH ROW EXECUTE FUNCTION "public"."listings_check"();



CREATE OR REPLACE TRIGGER "offers_before_insert" BEFORE INSERT ON "public"."offers" FOR EACH ROW EXECUTE FUNCTION "public"."offers_before_insert"();



CREATE OR REPLACE TRIGGER "products_special" BEFORE INSERT OR UPDATE OF "name", "variant", "rarity", "set_id" ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."products_special"();



CREATE OR REPLACE TRIGGER "sets_english_name" BEFORE INSERT OR UPDATE OF "name" ON "public"."sets" FOR EACH ROW EXECUTE FUNCTION "public"."sets_english_name"();



CREATE OR REPLACE TRIGGER "sets_inherit_hidden" BEFORE INSERT OR UPDATE OF "series_id" ON "public"."sets" FOR EACH ROW EXECUTE FUNCTION "public"."sets_inherit_hidden"();



CREATE OR REPLACE TRIGGER "sold_screen" AFTER INSERT ON "public"."sold_listings" REFERENCING NEW TABLE AS "new_rows" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sold_after_insert"();



ALTER TABLE ONLY "public"."alert_events"
    ADD CONSTRAINT "alert_events_alert_id_fkey" FOREIGN KEY ("alert_id") REFERENCES "public"."price_alerts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alert_events"
    ADD CONSTRAINT "alert_events_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alert_events"
    ADD CONSTRAINT "alert_events_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."ask_listings"
    ADD CONSTRAINT "ask_listings_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."binder_shares"
    ADD CONSTRAINT "binder_shares_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_cart_id_fkey" FOREIGN KEY ("cart_id") REFERENCES "public"."carts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."carts"
    ADD CONSTRAINT "carts_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."collection_items"
    ADD CONSTRAINT "collection_items_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."collection_items"
    ADD CONSTRAINT "collection_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_followee_fkey" FOREIGN KEY ("followee") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_follower_fkey" FOREIGN KEY ("follower") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."offer_messages"
    ADD CONSTRAINT "offer_messages_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."offers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."offer_messages"
    ADD CONSTRAINT "offer_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."offers"
    ADD CONSTRAINT "offers_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."offers"
    ADD CONSTRAINT "offers_listing_id_fkey" FOREIGN KEY ("listing_id") REFERENCES "public"."listings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."offers"
    ADD CONSTRAINT "offers_seller_id_fkey" FOREIGN KEY ("seller_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."portfolio_snapshots"
    ADD CONSTRAINT "portfolio_snapshots_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."price_alerts"
    ADD CONSTRAINT "price_alerts_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_alerts"
    ADD CONSTRAINT "price_alerts_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_game_id_fkey" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_set_id_fkey" FOREIGN KEY ("set_id") REFERENCES "public"."sets"("id");



ALTER TABLE ONLY "public"."profile_contacts"
    ADD CONSTRAINT "profile_contacts_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scan_log"
    ADD CONSTRAINT "scan_log_chosen_catalog_id_fkey" FOREIGN KEY ("chosen_catalog_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."scan_log"
    ADD CONSTRAINT "scan_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."series"
    ADD CONSTRAINT "series_game_id_fkey" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id");



ALTER TABLE ONLY "public"."set_links"
    ADD CONSTRAINT "set_links_set_id_fkey" FOREIGN KEY ("set_id") REFERENCES "public"."sets"("id");



ALTER TABLE ONLY "public"."sets"
    ADD CONSTRAINT "sets_game_id_fkey" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id");



ALTER TABLE ONLY "public"."sets"
    ADD CONSTRAINT "sets_series_id_fkey" FOREIGN KEY ("series_id") REFERENCES "public"."series"("id");



ALTER TABLE ONLY "public"."sold_listings"
    ADD CONSTRAINT "sold_listings_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tcgp_groups"
    ADD CONSTRAINT "tcgp_groups_set_id_fkey" FOREIGN KEY ("set_id") REFERENCES "public"."sets"("id");



ALTER TABLE ONLY "public"."trade_ledger"
    ADD CONSTRAINT "trade_ledger_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_ledger"
    ADD CONSTRAINT "trade_ledger_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."trade_proposals"
    ADD CONSTRAINT "trade_proposals_from_user_fkey" FOREIGN KEY ("from_user") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_proposals"
    ADD CONSTRAINT "trade_proposals_to_user_fkey" FOREIGN KEY ("to_user") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_ratings"
    ADD CONSTRAINT "trade_ratings_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."offers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_ratings"
    ADD CONSTRAINT "trade_ratings_ratee_id_fkey" FOREIGN KEY ("ratee_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_ratings"
    ADD CONSTRAINT "trade_ratings_rater_id_fkey" FOREIGN KEY ("rater_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wants"
    ADD CONSTRAINT "wants_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wants"
    ADD CONSTRAINT "wants_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE "public"."_backup_fn_20261022" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."_backup_products_20261022" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."_bulba_pages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."_merged_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."_resync_baseline" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "a_own" ON "public"."price_alerts" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."alert_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ask_fetch_state" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ask_listings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "b_own" ON "public"."binder_shares" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."binder_shares" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "c_all" ON "public"."profile_contacts" TO "authenticated" USING (("id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "c_read" ON "public"."profile_contacts" FOR SELECT TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_connected"("id", ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."cart_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."carts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalog_cards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalog_exclusions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalog_fetch_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalog_health_ignore" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalog_lookup_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "catalog_read" ON "public"."games" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "catalog_read" ON "public"."products" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "catalog_read" ON "public"."series" FOR SELECT TO "authenticated" USING ((NOT "hidden"));



CREATE POLICY "catalog_read" ON "public"."sets" FOR SELECT TO "authenticated" USING ((NOT "hidden"));



ALTER TABLE "public"."catalog_sets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."collection_import" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."collection_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dbs_official" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dbs_official_series" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "e_read" ON "public"."alert_events" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "e_seen" ON "public"."alert_events" FOR UPDATE TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."ebay_auth" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "f_del" ON "public"."follows" FOR DELETE TO "authenticated" USING ((("follower" = ( SELECT "auth"."uid"() AS "uid")) OR ("followee" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "f_ins" ON "public"."follows" FOR INSERT TO "authenticated" WITH CHECK ((("follower" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'pending'::"text")));



CREATE POLICY "f_read" ON "public"."follows" FOR SELECT TO "authenticated" USING ((("follower" = ( SELECT "auth"."uid"() AS "uid")) OR ("followee" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "f_upd" ON "public"."follows" FOR UPDATE TO "authenticated" USING (("followee" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("followee" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fx_rates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fx_read" ON "public"."fx_rates" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."games" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."img_probe" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."img_probe_ptcg" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."import_plan" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jp_logo_urls" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jp_set_logo_files" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jp_set_names" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "l_own" ON "public"."listings" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "l_read" ON "public"."listings" FOR SELECT TO "authenticated" USING ("public"."i_follow"("owner_id"));



ALTER TABLE "public"."listings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "m_ins" ON "public"."offer_messages" FOR INSERT TO "authenticated" WITH CHECK ((("sender_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."offers" "o"
  WHERE (("o"."id" = "offer_messages"."offer_id") AND (("o"."buyer_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("o"."seller_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



CREATE POLICY "m_read" ON "public"."offer_messages" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."offers" "o"
  WHERE (("o"."id" = "offer_messages"."offer_id") AND (("o"."buyer_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("o"."seller_id" = ( SELECT "auth"."uid"() AS "uid")))))));



ALTER TABLE "public"."news_feeds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "news_read" ON "public"."news_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "o_ins" ON "public"."offers" FOR INSERT TO "authenticated" WITH CHECK (("buyer_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "o_read" ON "public"."offers" FOR SELECT TO "authenticated" USING ((("buyer_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("seller_id" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."offer_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."offers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."op_logo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."op_official" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."op_official_series" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "own_cart_items" ON "public"."cart_items" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "own_carts" ON "public"."carts" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "own_collection" ON "public"."collection_items" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "own_ledger" ON "public"."trade_ledger" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "own_snapshots" ON "public"."portfolio_snapshots" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "p_ins" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "p_read" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "p_upd" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."pcom_expansions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pokemon_species_names" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."portfolio_snapshots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."price_alerts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profile_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ptcg_alt" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "r_ins" ON "public"."trade_ratings" FOR INSERT TO "authenticated" WITH CHECK ((("rater_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."offers" "o"
  WHERE (("o"."id" = "trade_ratings"."offer_id") AND ("o"."status" = 'received'::"text") AND ((("o"."buyer_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("o"."seller_id" = "trade_ratings"."ratee_id")) OR (("o"."seller_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("o"."buyer_id" = "trade_ratings"."ratee_id"))))))));



CREATE POLICY "r_read" ON "public"."trade_ratings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "read asking listings" ON "public"."ask_listings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "read species names" ON "public"."pokemon_species_names" FOR SELECT USING (true);



ALTER TABLE "public"."scan_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."set_checklist" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."set_checklist_runs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."set_count_check" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."set_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sl_own" ON "public"."scan_log" TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "sold_decide" ON "public"."sold_listings" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."sold_listings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sold_read" ON "public"."sold_listings" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."sync_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tcgp_groups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tcgp_printings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tcgp_reconcile_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tp_ins" ON "public"."trade_proposals" FOR INSERT TO "authenticated" WITH CHECK ((("from_user" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'proposed'::"text") AND (NOT "from_done") AND (NOT "to_done") AND "public"."is_connected"("from_user", "to_user")));



CREATE POLICY "tp_read" ON "public"."trade_proposals" FOR SELECT TO "authenticated" USING ((("from_user" = ( SELECT "auth"."uid"() AS "uid")) OR ("to_user" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."trade_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trade_proposals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trade_ratings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "upcoming_read" ON "public"."upcoming_sets" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."upcoming_sets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."variant_audit" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "w_own" ON "public"."wants" TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "w_read" ON "public"."wants" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_connected"("owner_id", ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."wants" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_promo_printings"("p_set" bigint, "p_apply" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_promo_printings"("p_set" bigint, "p_apply" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."adjust_collection"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_delta" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."adjust_collection"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_delta" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."apitcg_get"("path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apitcg_get"("path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ask_lot_flag"("title" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ask_lot_flag"("title" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ask_lot_flag"("title" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ask_title_flag"("title" "text", "grade" "text", "num" "text", "lang" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ask_title_flag"("title" "text", "grade" "text", "num" "text", "lang" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ask_title_flag"("title" "text", "grade" "text", "num" "text", "lang" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_card_variants"("p_tid" "text", "p_lang" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."audit_card_variants"("p_tid" "text", "p_lang" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_card_variants"("p_tid" "text", "p_lang" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_variants_batch"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."audit_variants_batch"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_variants_batch"("max_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."avg_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."avg_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_portfolio"("p_weeks" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_portfolio"("p_weeks" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_portfolio"("p_weeks" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."blend_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text", "p_added" integer, "p_price" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."blend_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text", "p_added" integer, "p_price" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."blend_cost"("p_owner" "uuid", "p_product" bigint, "p_condition" "text", "p_grade" "text", "p_added" integer, "p_price" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bulba_entry_name"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bulba_entry_name"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulba_entry_name"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulba_list_entries"("w" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bulba_list_entries"("w" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulba_list_entries"("w" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulba_logo"("p_prefix" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bulba_logo"("p_prefix" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulba_logo"("p_prefix" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulba_name_suffix"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bulba_name_suffix"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulba_name_suffix"("t" "text") TO "service_role";



GRANT ALL ON TABLE "public"."sets" TO "anon";
GRANT ALL ON TABLE "public"."sets" TO "authenticated";
GRANT ALL ON TABLE "public"."sets" TO "service_role";



GRANT ALL ON FUNCTION "public"."bulba_page_for"("s" "public"."sets") TO "anon";
GRANT ALL ON FUNCTION "public"."bulba_page_for"("s" "public"."sets") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulba_page_for"("s" "public"."sets") TO "service_role";



GRANT ALL ON FUNCTION "public"."cap_words"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cap_words"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cap_words"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."card_key"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."card_key"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."card_key"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."catalog_series_name"("tcg" "text", "code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."catalog_series_name"("tcg" "text", "code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."catalog_series_name"("tcg" "text", "code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."catalog_stats"("p_games" "text"[], "p_lang" "text", "p_kind" "text", "p_series" bigint[], "p_sets" bigint[], "p_owned" boolean, "p_q" "text", "p_special" "text"[], "p_cond" "text", "p_grade" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."catalog_stats"("p_games" "text"[], "p_lang" "text", "p_kind" "text", "p_series" bigint[], "p_sets" bigint[], "p_owned" boolean, "p_q" "text", "p_special" "text"[], "p_cond" "text", "p_grade" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."catalog_stats"("p_games" "text"[], "p_lang" "text", "p_kind" "text", "p_series" bigint[], "p_sets" bigint[], "p_owned" boolean, "p_q" "text", "p_special" "text"[], "p_cond" "text", "p_grade" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_alerts"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_alerts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_alerts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_insights_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_insights_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_magic_counts"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_magic_counts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_magic_counts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_ygo_counts"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_ygo_counts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_ygo_counts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."checklist_num_ok"("code" "text", "num" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."checklist_num_ok"("code" "text", "num" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."checklist_num_ok"("code" "text", "num" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."classify_special"("set_name" "text", "name" "text", "variant" "text", "rarity" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."classify_special"("set_name" "text", "name" "text", "variant" "text", "rarity" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."classify_special"("set_name" "text", "name" "text", "variant" "text", "rarity" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_cart"("p_cart" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_cart"("p_cart" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ebay_browse_token"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ebay_browse_token"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ebay_get"("url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ebay_get"("url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ebay_token"("p_scope" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ebay_token"("p_scope" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."enrich_pokemon_cards"("max_cards" integer, "p_set_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."enrich_pokemon_cards"("max_cards" integer, "p_set_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."enrich_pokemon_cards"("max_cards" integer, "p_set_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fetch_ask_prices"("max_q" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fetch_ask_prices"("max_q" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_news"() TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_news"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_news"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_bulba_checklist"("sid" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_bulba_checklist"("sid" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_bulba_checklist"("sid" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_bulba_logos"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_bulba_logos"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_bulba_logos"("max_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_bulba_logos_by_code"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_bulba_logos_by_code"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_bulba_logos_by_code"("max_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_dbs_masters_pack_images"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_dbs_masters_pack_images"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_dbs_masters_pack_images"("max_n" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fill_dbs_official"("p_game" "text", "p_series" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fill_dbs_official"("p_game" "text", "p_series" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_dbs_pack_images"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_dbs_pack_images"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_dbs_pack_images"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_missing_from_checklist"("sid" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_missing_from_checklist"("sid" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_missing_from_checklist"("sid" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_onepiece_pack_images"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_onepiece_pack_images"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_onepiece_pack_images"("max_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_op_official"("p_series" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fill_op_official"("p_series" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_op_official"("p_series" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_series_logos"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_series_logos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_series_logos"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_tcgdex_logos"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_tcgdex_logos"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_tcgdex_logos"("max_n" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fill_tcgp_group"("p_group" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fill_tcgp_group"("p_group" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_yugipedia_logos"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fill_yugipedia_logos"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_yugipedia_logos"("max_n" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."friend_tradeables"("p_friend" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."friend_tradeables"("p_friend" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."friend_tradeables"("p_friend" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_vendor_listing"("p_handle" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_vendor_listing"("p_handle" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_vendor_listing"("p_handle" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."grade_from_title"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."grade_from_title"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."grade_from_title"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_setup"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_setup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_setup"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."i_follow"("owner" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."i_follow"("owner" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."i_follow"("owner" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."import_collection"("p_lines" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."import_collection"("p_lines" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_collection"("p_lines" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."import_pair_items"() TO "anon";
GRANT ALL ON FUNCTION "public"."import_pair_items"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_pair_items"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_connected"("a" "uuid", "b" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_connected"("a" "uuid", "b" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_connected"("a" "uuid", "b" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."jp_card_name_en"("jp" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."jp_card_name_en"("jp" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."jp_card_name_en"("jp" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."jp_card_name_en2"("jp" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."jp_card_name_en2"("jp" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."jp_card_name_en2"("jp" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."jp_norm"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."jp_norm"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."jp_norm"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."limitless_jp_url"("p_code" "text", "p_num" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."limitless_jp_url"("p_code" "text", "p_num" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."limitless_jp_url"("p_code" "text", "p_num" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_dbs_official_series"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_dbs_official_series"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_tcgp_groups"("p_category" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_tcgp_groups"("p_category" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."listings_check"() TO "anon";
GRANT ALL ON FUNCTION "public"."listings_check"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listings_check"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_import"("p_rows" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."match_import"("p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_import"("p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."merge_product"("src" bigint, "tgt" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_product"("src" bigint, "tgt" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."move_items"("p_from" "uuid", "p_to" "uuid", "p_items" "jsonb", "p_ref" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."move_items"("p_from" "uuid", "p_to" "uuid", "p_items" "jsonb", "p_ref" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."mtg_finish"("f" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."mtg_finish"("f" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mtg_finish"("f" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."norm"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."norm"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."norm"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."num_key"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."num_key"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."num_key"("t" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."offer_action"("p_offer" bigint, "p_action" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."offer_action"("p_offer" bigint, "p_action" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."offer_action"("p_offer" bigint, "p_action" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."offers_before_insert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."offers_before_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."op_norm"("n" "text", "num" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."op_norm"("n" "text", "num" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."op_norm"("n" "text", "num" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."op_official_logos"("p_batch" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."op_official_logos"("p_batch" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."op_tag"("n" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."op_tag"("n" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."op_tag"("n" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."op_variant"("n" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."op_variant"("n" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."op_variant"("n" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."pcom_image_url"("p_tcgdex_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."pcom_image_url"("p_tcgdex_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pcom_image_url"("p_tcgdex_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."pcom_slug_candidates"("s" "public"."sets") TO "anon";
GRANT ALL ON FUNCTION "public"."pcom_slug_candidates"("s" "public"."sets") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pcom_slug_candidates"("s" "public"."sets") TO "service_role";



REVOKE ALL ON FUNCTION "public"."phase1_selftest"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."phase1_selftest"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."phase3_selftest"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."phase3_selftest"() TO "service_role";



GRANT ALL ON FUNCTION "public"."price_as_of"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_kind" "text", "p_day" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."price_as_of"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_kind" "text", "p_day" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."price_as_of"("p_product" bigint, "p_condition" "text", "p_grade" "text", "p_kind" "text", "p_day" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."probe_limitless_jp"("p_batch" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."probe_limitless_jp"("p_batch" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."probe_pcom_expansion"("sid" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."probe_pcom_expansion"("sid" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."probe_pcom_expansion"("sid" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."probe_ptcg_alt"("p_batch" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."probe_ptcg_alt"("p_batch" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."product_in_use"("p" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."product_in_use"("p" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."products_special"() TO "anon";
GRANT ALL ON FUNCTION "public"."products_special"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."products_special"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."profile_stats"("p_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."profile_stats"("p_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."profile_stats"("p_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."ptcg_image_url"("p_tcgdex_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ptcg_image_url"("p_tcgdex_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ptcg_image_url"("p_tcgdex_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ptcg_set_code"("c" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ptcg_set_code"("c" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ptcg_set_code"("c" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."public_binder"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."public_binder"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."public_binder"("p_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reconcile_set_with_tcgp"("p_set" bigint, "p_apply" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reconcile_set_with_tcgp"("p_set" bigint, "p_apply" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_card_images"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_card_images"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_card_images"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_fx"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_fx"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_fx"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_set_covers"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_set_covers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_set_covers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reverse_pattern_label"("foil" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reverse_pattern_label"("foil" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reverse_pattern_label"("foil" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_catalog_checks"("max_sets" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."run_catalog_checks"("max_sets" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_catalog_checks"("max_sets" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."safe_ts"("v" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."safe_ts"("v" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."safe_ts"("v" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."screen_ask_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."screen_ask_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."screen_ask_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."screen_sold_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."screen_sold_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."screen_sold_group"("p_product" bigint, "p_market" "text", "p_condition" "text", "p_grade" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."scryfall_get"("url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."scryfall_get"("url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."scryfall_get"("url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sealed_title_flag"("title" "text", "pname" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sealed_title_flag"("title" "text", "pname" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sealed_title_flag"("title" "text", "pname" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_completion"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_completion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_completion"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sets_english_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."sets_english_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sets_english_name"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sets_inherit_hidden"() TO "anon";
GRANT ALL ON FUNCTION "public"."sets_inherit_hidden"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sets_inherit_hidden"() TO "service_role";



GRANT ALL ON FUNCTION "public"."snapshot_portfolio"("p_day" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_portfolio"("p_day" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_portfolio"("p_day" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."sold_after_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."sold_after_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sold_after_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sold_is_credible"("excluded" boolean, "user_decision" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sold_is_credible"("excluded" boolean, "user_decision" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sold_is_credible"("excluded" boolean, "user_decision" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sold_title_flag"("title" "text", "grade" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sold_title_flag"("title" "text", "grade" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sold_title_flag"("title" "text", "grade" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strip_num"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strip_num"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strip_num"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_jp_bulbapedia"("sid" bigint, "official" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sync_jp_bulbapedia"("sid" bigint, "official" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_jp_bulbapedia"("sid" bigint, "official" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_jp_limitless"("sid" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."sync_jp_limitless"("sid" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_jp_limitless"("sid" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_one_set"("sid" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."sync_one_set"("sid" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_one_set"("sid" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_set_lists"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_set_lists"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_set_lists"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_tick"("max_sets" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sync_tick"("max_sets" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_tick"("max_sets" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgdex_variant_labels"("vd" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgdex_variant_labels"("vd" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgdex_variant_labels"("vd" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."tcgp_allows"("p_set" bigint, "p_number" "text", "p_variant" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tcgp_allows"("p_set" bigint, "p_number" "text", "p_variant" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_norm"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_norm"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_norm"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_num"("n" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_num"("n" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_num"("n" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_our_tag"("p_name" "text", "p_variant" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_our_tag"("p_name" "text", "p_variant" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_our_tag"("p_name" "text", "p_variant" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_pattern"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_pattern"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_pattern"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_promo_tag"("t" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_promo_tag"("t" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_promo_tag"("t" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_their_tag"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_their_tag"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_their_tag"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_variant_key"("v" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_variant_key"("v" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_variant_key"("v" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tcgp_variant_label"("sub_type" "text", "pattern" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tcgp_variant_label"("sub_type" "text", "pattern" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tcgp_variant_label"("sub_type" "text", "pattern" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."trade_action"("p_id" bigint, "p_action" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trade_action"("p_id" bigint, "p_action" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trade_action"("p_id" bigint, "p_action" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."upgrade_images_tcg_pcom"("max_n" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."upgrade_images_tcg_pcom"("max_n" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upgrade_images_tcg_pcom"("max_n" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."upgrade_pokemon_images"("max_n" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upgrade_pokemon_images"("max_n" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."upgrade_pokemon_images_pcom"("max_n" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upgrade_pokemon_images_pcom"("max_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vintage_jp_check"("sid" bigint, "p_apply" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vintage_jp_check"("sid" bigint, "p_apply" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vintage_jp_check"("sid" bigint, "p_apply" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."_backup_fn_20261022" TO "anon";
GRANT ALL ON TABLE "public"."_backup_fn_20261022" TO "authenticated";
GRANT ALL ON TABLE "public"."_backup_fn_20261022" TO "service_role";



GRANT ALL ON TABLE "public"."_backup_products_20261022" TO "anon";
GRANT ALL ON TABLE "public"."_backup_products_20261022" TO "authenticated";
GRANT ALL ON TABLE "public"."_backup_products_20261022" TO "service_role";



GRANT ALL ON TABLE "public"."_bulba_pages" TO "anon";
GRANT ALL ON TABLE "public"."_bulba_pages" TO "authenticated";
GRANT ALL ON TABLE "public"."_bulba_pages" TO "service_role";



GRANT ALL ON TABLE "public"."_merged_products" TO "anon";
GRANT ALL ON TABLE "public"."_merged_products" TO "authenticated";
GRANT ALL ON TABLE "public"."_merged_products" TO "service_role";



GRANT ALL ON TABLE "public"."_resync_baseline" TO "anon";
GRANT ALL ON TABLE "public"."_resync_baseline" TO "authenticated";
GRANT ALL ON TABLE "public"."_resync_baseline" TO "service_role";



GRANT ALL ON TABLE "public"."alert_events" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."alert_events" TO "authenticated";
GRANT ALL ON TABLE "public"."alert_events" TO "service_role";



GRANT UPDATE("seen") ON TABLE "public"."alert_events" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."alert_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."alert_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."alert_events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."api_usage" TO "anon";
GRANT ALL ON TABLE "public"."api_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."api_usage" TO "service_role";



GRANT ALL ON TABLE "public"."fx_rates" TO "anon";
GRANT ALL ON TABLE "public"."fx_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."fx_rates" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sold_listings" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sold_listings" TO "authenticated";
GRANT ALL ON TABLE "public"."sold_listings" TO "service_role";



GRANT UPDATE("user_decision") ON TABLE "public"."sold_listings" TO "authenticated";



GRANT UPDATE("decided_at") ON TABLE "public"."sold_listings" TO "authenticated";



GRANT ALL ON TABLE "public"."market_price_v" TO "anon";
GRANT ALL ON TABLE "public"."market_price_v" TO "authenticated";
GRANT ALL ON TABLE "public"."market_price_v" TO "service_role";



GRANT ALL ON TABLE "public"."arbitrage_v" TO "anon";
GRANT ALL ON TABLE "public"."arbitrage_v" TO "authenticated";
GRANT ALL ON TABLE "public"."arbitrage_v" TO "service_role";



GRANT ALL ON TABLE "public"."ask_fetch_state" TO "anon";
GRANT ALL ON TABLE "public"."ask_fetch_state" TO "authenticated";
GRANT ALL ON TABLE "public"."ask_fetch_state" TO "service_role";



GRANT ALL ON TABLE "public"."ask_listings" TO "anon";
GRANT ALL ON TABLE "public"."ask_listings" TO "authenticated";
GRANT ALL ON TABLE "public"."ask_listings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ask_listings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ask_listings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ask_listings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ask_price_v" TO "anon";
GRANT ALL ON TABLE "public"."ask_price_v" TO "authenticated";
GRANT ALL ON TABLE "public"."ask_price_v" TO "service_role";



GRANT ALL ON TABLE "public"."binder_shares" TO "anon";
GRANT ALL ON TABLE "public"."binder_shares" TO "authenticated";
GRANT ALL ON TABLE "public"."binder_shares" TO "service_role";



GRANT ALL ON TABLE "public"."cart_items" TO "anon";
GRANT ALL ON TABLE "public"."cart_items" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cart_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cart_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cart_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."carts" TO "anon";
GRANT ALL ON TABLE "public"."carts" TO "authenticated";
GRANT ALL ON TABLE "public"."carts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."carts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."carts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."carts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_cards" TO "anon";
GRANT ALL ON TABLE "public"."catalog_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_cards" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_exclusions" TO "anon";
GRANT ALL ON TABLE "public"."catalog_exclusions" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_exclusions" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_fetch_log" TO "anon";
GRANT ALL ON TABLE "public"."catalog_fetch_log" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_fetch_log" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_health" TO "anon";
GRANT ALL ON TABLE "public"."catalog_health" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_health" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_health_ignore" TO "anon";
GRANT ALL ON TABLE "public"."catalog_health_ignore" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_health_ignore" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_lookup_log" TO "anon";
GRANT ALL ON TABLE "public"."catalog_lookup_log" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_lookup_log" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_sets" TO "anon";
GRANT ALL ON TABLE "public"."catalog_sets" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_sets" TO "service_role";



GRANT ALL ON TABLE "public"."collection_items" TO "anon";
GRANT ALL ON TABLE "public"."collection_items" TO "authenticated";
GRANT ALL ON TABLE "public"."collection_items" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."series" TO "anon";
GRANT ALL ON TABLE "public"."series" TO "authenticated";
GRANT ALL ON TABLE "public"."series" TO "service_role";



GRANT ALL ON TABLE "public"."catalog_v" TO "authenticated";
GRANT ALL ON TABLE "public"."catalog_v" TO "service_role";



GRANT ALL ON TABLE "public"."collection_import" TO "anon";
GRANT ALL ON TABLE "public"."collection_import" TO "authenticated";
GRANT ALL ON TABLE "public"."collection_import" TO "service_role";



GRANT ALL ON SEQUENCE "public"."collection_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."collection_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."collection_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dbs_official" TO "service_role";



GRANT ALL ON TABLE "public"."dbs_official_series" TO "service_role";



GRANT ALL ON TABLE "public"."ebay_auth" TO "service_role";



GRANT ALL ON TABLE "public"."follows" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."follows" TO "authenticated";
GRANT ALL ON TABLE "public"."follows" TO "service_role";



GRANT UPDATE("status") ON TABLE "public"."follows" TO "authenticated";



GRANT ALL ON TABLE "public"."games" TO "anon";
GRANT ALL ON TABLE "public"."games" TO "authenticated";
GRANT ALL ON TABLE "public"."games" TO "service_role";



GRANT ALL ON TABLE "public"."img_probe" TO "anon";
GRANT ALL ON TABLE "public"."img_probe" TO "authenticated";
GRANT ALL ON TABLE "public"."img_probe" TO "service_role";



GRANT ALL ON TABLE "public"."img_probe_ptcg" TO "anon";
GRANT ALL ON TABLE "public"."img_probe_ptcg" TO "authenticated";
GRANT ALL ON TABLE "public"."img_probe_ptcg" TO "service_role";



GRANT ALL ON TABLE "public"."import_expect" TO "service_role";



GRANT ALL ON TABLE "public"."import_plan" TO "service_role";



GRANT ALL ON TABLE "public"."jp_logo_urls" TO "anon";
GRANT ALL ON TABLE "public"."jp_logo_urls" TO "authenticated";
GRANT ALL ON TABLE "public"."jp_logo_urls" TO "service_role";



GRANT ALL ON TABLE "public"."jp_set_logo_files" TO "anon";
GRANT ALL ON TABLE "public"."jp_set_logo_files" TO "authenticated";
GRANT ALL ON TABLE "public"."jp_set_logo_files" TO "service_role";



GRANT ALL ON TABLE "public"."jp_set_names" TO "anon";
GRANT ALL ON TABLE "public"."jp_set_names" TO "authenticated";
GRANT ALL ON TABLE "public"."jp_set_names" TO "service_role";



GRANT ALL ON TABLE "public"."listings" TO "anon";
GRANT ALL ON TABLE "public"."listings" TO "authenticated";
GRANT ALL ON TABLE "public"."listings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."listings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."listings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."listings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."news_feeds" TO "anon";
GRANT ALL ON TABLE "public"."news_feeds" TO "authenticated";
GRANT ALL ON TABLE "public"."news_feeds" TO "service_role";



GRANT ALL ON TABLE "public"."news_items" TO "anon";
GRANT ALL ON TABLE "public"."news_items" TO "authenticated";
GRANT ALL ON TABLE "public"."news_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."news_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."news_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."news_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."offer_messages" TO "anon";
GRANT ALL ON TABLE "public"."offer_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."offer_messages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."offer_messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."offer_messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."offer_messages_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."offers" TO "anon";
GRANT ALL ON TABLE "public"."offers" TO "authenticated";
GRANT ALL ON TABLE "public"."offers" TO "service_role";



GRANT ALL ON SEQUENCE "public"."offers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."offers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."offers_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."op_logo" TO "anon";
GRANT ALL ON TABLE "public"."op_logo" TO "authenticated";
GRANT ALL ON TABLE "public"."op_logo" TO "service_role";



GRANT ALL ON TABLE "public"."op_official" TO "anon";
GRANT ALL ON TABLE "public"."op_official" TO "authenticated";
GRANT ALL ON TABLE "public"."op_official" TO "service_role";



GRANT ALL ON TABLE "public"."op_official_series" TO "anon";
GRANT ALL ON TABLE "public"."op_official_series" TO "authenticated";
GRANT ALL ON TABLE "public"."op_official_series" TO "service_role";



GRANT ALL ON TABLE "public"."pcom_expansions" TO "anon";
GRANT ALL ON TABLE "public"."pcom_expansions" TO "authenticated";
GRANT ALL ON TABLE "public"."pcom_expansions" TO "service_role";



GRANT ALL ON TABLE "public"."pokemon_species_names" TO "anon";
GRANT ALL ON TABLE "public"."pokemon_species_names" TO "authenticated";
GRANT ALL ON TABLE "public"."pokemon_species_names" TO "service_role";



GRANT ALL ON TABLE "public"."portfolio_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."portfolio_snapshots" TO "authenticated";
GRANT ALL ON TABLE "public"."portfolio_snapshots" TO "service_role";



GRANT ALL ON TABLE "public"."price_alerts" TO "anon";
GRANT ALL ON TABLE "public"."price_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."price_alerts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."price_alerts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."price_alerts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."price_alerts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."price_v" TO "anon";
GRANT ALL ON TABLE "public"."price_v" TO "authenticated";
GRANT ALL ON TABLE "public"."price_v" TO "service_role";



GRANT ALL ON TABLE "public"."product_tcgp_keys" TO "service_role";



GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profile_contacts" TO "anon";
GRANT ALL ON TABLE "public"."profile_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."ptcg_alt" TO "anon";
GRANT ALL ON TABLE "public"."ptcg_alt" TO "authenticated";
GRANT ALL ON TABLE "public"."ptcg_alt" TO "service_role";



GRANT ALL ON TABLE "public"."scan_log" TO "anon";
GRANT ALL ON TABLE "public"."scan_log" TO "authenticated";
GRANT ALL ON TABLE "public"."scan_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."scan_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."scan_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."scan_log_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."series_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."series_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."series_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."set_card_totals" TO "anon";
GRANT ALL ON TABLE "public"."set_card_totals" TO "authenticated";
GRANT ALL ON TABLE "public"."set_card_totals" TO "service_role";



GRANT ALL ON TABLE "public"."set_checklist" TO "anon";
GRANT ALL ON TABLE "public"."set_checklist" TO "authenticated";
GRANT ALL ON TABLE "public"."set_checklist" TO "service_role";



GRANT ALL ON TABLE "public"."set_checklist_runs" TO "anon";
GRANT ALL ON TABLE "public"."set_checklist_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."set_checklist_runs" TO "service_role";



GRANT ALL ON TABLE "public"."set_checklist_current" TO "anon";
GRANT ALL ON TABLE "public"."set_checklist_current" TO "authenticated";
GRANT ALL ON TABLE "public"."set_checklist_current" TO "service_role";



GRANT ALL ON TABLE "public"."set_count_check" TO "anon";
GRANT ALL ON TABLE "public"."set_count_check" TO "authenticated";
GRANT ALL ON TABLE "public"."set_count_check" TO "service_role";



GRANT ALL ON TABLE "public"."set_links" TO "anon";
GRANT ALL ON TABLE "public"."set_links" TO "authenticated";
GRANT ALL ON TABLE "public"."set_links" TO "service_role";



GRANT ALL ON TABLE "public"."set_ratio_v" TO "anon";
GRANT ALL ON TABLE "public"."set_ratio_v" TO "authenticated";
GRANT ALL ON TABLE "public"."set_ratio_v" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sets_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sets_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sets_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sold_listings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sold_listings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sold_listings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sold_review_v" TO "anon";
GRANT ALL ON TABLE "public"."sold_review_v" TO "authenticated";
GRANT ALL ON TABLE "public"."sold_review_v" TO "service_role";



GRANT ALL ON TABLE "public"."sync_log" TO "anon";
GRANT ALL ON TABLE "public"."sync_log" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tcgp_groups" TO "service_role";



GRANT ALL ON TABLE "public"."tcgp_printings" TO "service_role";



GRANT ALL ON TABLE "public"."tcgp_keys" TO "service_role";



GRANT ALL ON TABLE "public"."tcgp_reconcile_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tcgp_reconcile_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tcgp_reconcile_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tcgp_reconcile_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tcgp_set_fit" TO "service_role";



GRANT ALL ON TABLE "public"."trade_ledger" TO "anon";
GRANT ALL ON TABLE "public"."trade_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."trade_ledger" TO "service_role";



GRANT ALL ON SEQUENCE "public"."trade_ledger_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."trade_ledger_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."trade_ledger_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."trade_proposals" TO "anon";
GRANT ALL ON TABLE "public"."trade_proposals" TO "authenticated";
GRANT ALL ON TABLE "public"."trade_proposals" TO "service_role";



GRANT ALL ON SEQUENCE "public"."trade_proposals_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."trade_proposals_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."trade_proposals_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."trade_ratings" TO "anon";
GRANT ALL ON TABLE "public"."trade_ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."trade_ratings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."trade_ratings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."trade_ratings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."trade_ratings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."upcoming_sets" TO "anon";
GRANT ALL ON TABLE "public"."upcoming_sets" TO "authenticated";
GRANT ALL ON TABLE "public"."upcoming_sets" TO "service_role";



GRANT ALL ON SEQUENCE "public"."upcoming_sets_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."upcoming_sets_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."upcoming_sets_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."variant_audit" TO "anon";
GRANT ALL ON TABLE "public"."variant_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."variant_audit" TO "service_role";



GRANT ALL ON TABLE "public"."variant_audit_candidates" TO "anon";
GRANT ALL ON TABLE "public"."variant_audit_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."variant_audit_candidates" TO "service_role";



GRANT ALL ON TABLE "public"."wants" TO "anon";
GRANT ALL ON TABLE "public"."wants" TO "authenticated";
GRANT ALL ON TABLE "public"."wants" TO "service_role";



GRANT ALL ON SEQUENCE "public"."wants_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."wants_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."wants_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







