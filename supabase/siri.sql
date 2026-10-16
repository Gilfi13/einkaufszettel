-- Siri / Kurzbefehle: Artikel per Sprache zur Liste hinzufügen.
-- Einmal im Supabase SQL-Editor ausführen.

create table if not exists public.shortcut_tokens (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  instance_id text not null,
  created_at timestamptz not null default now(),
  unique (user_id, instance_id)
);

-- Kein direkter Zugriff, nur über die Funktionen unten.
alter table public.shortcut_tokens enable row level security;

-- Liefert (oder erstellt) den persönlichen Siri-Schlüssel für eine Liste.
create or replace function public.get_shortcut_token(p_instance_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet';
  end if;

  if not exists (
    select 1 from instance_members
    where user_id = auth.uid() and instance_id::text = p_instance_id
  ) then
    raise exception 'Kein Mitglied dieser Liste';
  end if;

  select token into v_token from shortcut_tokens
  where user_id = auth.uid() and instance_id = p_instance_id;

  if v_token is null then
    v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into shortcut_tokens (token, user_id, instance_id)
    values (v_token, auth.uid(), p_instance_id);
  end if;

  return v_token;
end;
$$;

-- Neuer Schlüssel, falls der alte z.B. weitergegeben wurde.
create or replace function public.reset_shortcut_token(p_instance_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from shortcut_tokens where user_id = auth.uid() and instance_id = p_instance_id;
  return get_shortcut_token(p_instance_id);
end;
$$;

-- Wird vom Kurzbefehl aufgerufen. "Milch, Eier und Brot" -> drei Artikel.
-- Gibt einen Satz zurück, den Siri vorlesen kann.
create or replace function public.add_item_via_shortcut(p_token text, p_text text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row shortcut_tokens;
  v_nickname text;
  v_part text;
  v_names text[] := '{}';
begin
  select * into v_row from shortcut_tokens where token = p_token;
  if v_row is null then
    raise exception 'Ungültiger Schlüssel';
  end if;

  select nickname into v_nickname from profiles where id = v_row.user_id;

  foreach v_part in array regexp_split_to_array(coalesce(p_text, ''), '\s*(,|;|\n|\s+und\s+)\s*', 'i')
  loop
    v_part := btrim(v_part, ' .!?');
    if v_part <> '' then
      v_part := upper(left(v_part, 1)) || substr(v_part, 2);
      -- instance_id über instance_members holen, damit der Spaltentyp passt
      -- und nur Mitglieder etwas hinzufügen können.
      insert into shopping_items (instance_id, name, status, added_by, added_by_nickname)
      select im.instance_id, v_part, 'open', v_row.user_id, v_nickname
      from instance_members im
      where im.user_id = v_row.user_id and im.instance_id::text = v_row.instance_id
      limit 1;

      if not found then
        raise exception 'Kein Mitglied dieser Liste mehr';
      end if;
      v_names := v_names || v_part;
    end if;
  end loop;

  if array_length(v_names, 1) is null then
    return 'Ich habe nichts verstanden.';
  end if;

  if array_length(v_names, 1) = 1 then
    return v_names[1] || ' steht jetzt auf der Liste.';
  end if;

  return array_to_string(v_names[1:array_length(v_names, 1) - 1], ', ')
    || ' und ' || v_names[array_length(v_names, 1)] || ' stehen jetzt auf der Liste.';
end;
$$;

revoke all on function public.get_shortcut_token(text) from public, anon;
revoke all on function public.reset_shortcut_token(text) from public, anon;
grant execute on function public.get_shortcut_token(text) to authenticated;
grant execute on function public.reset_shortcut_token(text) to authenticated;
revoke all on function public.add_item_via_shortcut(text, text) from public;
grant execute on function public.add_item_via_shortcut(text, text) to anon, authenticated;
