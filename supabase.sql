-- =====================================================================
--  Élection des délégués (v2, avec administration)
--  À coller dans Supabase > SQL Editor > Run.
--  Fonctionne sur une base neuve ET sur la v1 déjà installée.
--
--  >>> AVANT DE LANCER : change le mot de passe admin à l'étape 4 <<<
-- =====================================================================

set search_path = public, extensions;
create extension if not exists pgcrypto;

-- 1. Tables ------------------------------------------------------------
create table if not exists public.election_eleves (
  identifiant text primary key,
  prenom      text not null,
  nom         text not null,
  a_vote      boolean not null default false
);

create table if not exists public.election_bulletins (
  id        uuid primary key default gen_random_uuid(),
  delegue   text not null,
  suppleant text not null,
  constraint candidats_differents check (delegue <> suppleant)
);

create table if not exists public.election_config (
  cle    text primary key,
  valeur text not null
);

-- 2. Mise à niveau v1 -> v2 : le bulletin est relié au votant
--    (nécessaire pour pouvoir annuler le vote d'un élève)
alter table public.election_bulletins add column if not exists votant text;

alter table public.election_bulletins drop constraint if exists election_bulletins_delegue_fkey;
alter table public.election_bulletins drop constraint if exists election_bulletins_suppleant_fkey;
alter table public.election_bulletins drop constraint if exists election_bulletins_votant_fkey;
alter table public.election_bulletins drop constraint if exists election_bulletins_votant_key;

alter table public.election_bulletins
  add constraint election_bulletins_delegue_fkey   foreign key (delegue)   references public.election_eleves(identifiant) on update cascade,
  add constraint election_bulletins_suppleant_fkey foreign key (suppleant) references public.election_eleves(identifiant) on update cascade,
  add constraint election_bulletins_votant_fkey    foreign key (votant)    references public.election_eleves(identifiant) on update cascade on delete cascade,
  add constraint election_bulletins_votant_key     unique (votant);

-- 3. Personne ne lit ni n'écrit les tables directement : tout passe par les fonctions
alter table public.election_eleves    enable row level security;
alter table public.election_bulletins enable row level security;
alter table public.election_config    enable row level security;
revoke all on public.election_eleves, public.election_bulletins, public.election_config from anon, authenticated;

-- 4. MOT DE PASSE ADMIN : remplace 'ChangeMoi-2026' par ton propre mot de passe
--    (relancer le script remet le mot de passe écrit ici)
insert into public.election_config (cle, valeur)
values ('mdp_admin', crypt('admin', gen_salt('bf')))
on conflict (cle) do update set valeur = excluded.valeur;

-- 5. Liste initiale des 31 élèves (insérée seulement si la table est vide ;
--    ensuite, tout se gère depuis la partie admin du site)
insert into public.election_eleves (identifiant, prenom, nom)
select * from (values
  ('aya','Aya','ABBES'), ('zainab','Zainab','ABOUMEJD'), ('omayma','Omayma','AITY'),
  ('romain','Romain','BERTRAND'), ('anais','Anais','BESIN'), ('nais','Nais','BOUISSEREN'),
  ('ikhlas','Ikhlas','BOUKHAMSA'), ('ambre','Ambre','CAMILLERI'), ('livia','Livia','CHARBONNIER'),
  ('isane','Isane','CHAUMEIX'), ('margot','Margot','CHEZE'), ('abderrahmane','Abderrahmane','EL BAZZARY'),
  ('inass','Inass','ELHAKIMI'), ('manon','Manon','FABRE'), ('alexia','Alexia','FAUBLADIER'),
  ('marieg','Marie','GASTAL'), ('nada','Nada','HANAN'), ('pierre','Pierre','KANDA'),
  ('adnane','Adnane','KOUNA'), ('branss','Branss','MANZALA KUMBI'), ('jessica','Jessica','MILLET'),
  ('alisson','Alisson','PORTEFAIX'), ('marier','Marie','RIGAUD'), ('leopoldine','Leopoldine','SAURON-VAN HILLE'),
  ('arthur','Arthur','SNASNI'), ('lea','Lea','TAVARES'), ('camille','Camille','THIOLIERE'),
  ('prune','Prune','TOURNEBIZE'), ('morgane','Morgane','VEERAMOOTOO'), ('jephthe','Jephthe','YUMA ABASSI'),
  ('haroun','Haroun','ZINE')
) as v(identifiant, prenom, nom)
where not exists (select 1 from public.election_eleves);

-- 6. Fonctions élèves -----------------------------------------------------

create or replace function public.election_liste()
returns table (identifiant text, prenom text, nom text)
language sql stable security definer set search_path = public as $$
  select identifiant, prenom, nom from election_eleves order by nom, prenom;
$$;

create or replace function public.election_connexion(p_identifiant text)
returns json language plpgsql security definer set search_path = public as $$
declare e election_eleves;
begin
  select * into e from election_eleves where identifiant = lower(trim(p_identifiant));
  if not found then
    return json_build_object('ok', false, 'erreur', 'identifiant_inconnu');
  end if;
  return json_build_object('ok', true, 'identifiant', e.identifiant,
                           'prenom', e.prenom, 'nom', e.nom, 'a_vote', e.a_vote);
end $$;

create or replace function public.election_voter(p_votant text, p_delegue text, p_suppleant text)
returns json language plpgsql security definer set search_path = public as $$
declare e election_eleves;
begin
  select * into e from election_eleves where identifiant = lower(trim(p_votant)) for update;
  if not found then return json_build_object('ok', false, 'erreur', 'identifiant_inconnu'); end if;
  if e.a_vote then return json_build_object('ok', false, 'erreur', 'deja_vote'); end if;
  if p_delegue is null or p_suppleant is null or p_delegue = p_suppleant then
    return json_build_object('ok', false, 'erreur', 'choix_invalide');
  end if;
  if not exists (select 1 from election_eleves where identifiant = p_delegue)
     or not exists (select 1 from election_eleves where identifiant = p_suppleant) then
    return json_build_object('ok', false, 'erreur', 'candidat_inconnu');
  end if;
  insert into election_bulletins (votant, delegue, suppleant) values (e.identifiant, p_delegue, p_suppleant);
  update election_eleves set a_vote = true where identifiant = e.identifiant;
  return json_build_object('ok', true);
end $$;

create or replace function public.election_resultats()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'inscrits', (select count(*) from election_eleves),
    'votants',  (select count(*) from election_eleves where a_vote),
    'delegue', coalesce((
      select json_agg(t order by t.voix desc, t.nom, t.prenom) from (
        select e.identifiant, e.prenom, e.nom, count(*)::int as voix
          from election_bulletins b join election_eleves e on e.identifiant = b.delegue
         group by e.identifiant, e.prenom, e.nom
         order by voix desc, e.nom, e.prenom limit 3) t), '[]'::json),
    'suppleant', coalesce((
      select json_agg(t order by t.voix desc, t.nom, t.prenom) from (
        select e.identifiant, e.prenom, e.nom, count(*)::int as voix
          from election_bulletins b join election_eleves e on e.identifiant = b.suppleant
         group by e.identifiant, e.prenom, e.nom
         order by voix desc, e.nom, e.prenom limit 3) t), '[]'::json)
  );
$$;

-- 7. Fonctions admin (toutes vérifient le mot de passe) ---------------------

create or replace function public.election_admin_ok(p_mdp text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from election_config
                  where cle = 'mdp_admin' and valeur = crypt(coalesce(p_mdp, ''), valeur));
$$;

create or replace function public.election_admin_verifier(p_mdp text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.election_admin_liste(p_mdp text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  return json_build_object('ok', true,
    'inscrits', (select count(*) from election_eleves),
    'votants',  (select count(*) from election_eleves where a_vote),
    'eleves', coalesce((select json_agg(t order by t.nom, t.prenom) from (
       select e.identifiant, e.prenom, e.nom, e.a_vote,
              (select count(*) from election_bulletins b where b.delegue   = e.identifiant)::int as voix_delegue,
              (select count(*) from election_bulletins b where b.suppleant = e.identifiant)::int as voix_suppleant
         from election_eleves e) t), '[]'::json));
end $$;

-- Contrôle commun des champs saisis par l'admin
create or replace function public.election_admin_controle(p_identifiant text, p_prenom text, p_nom text)
returns text language plpgsql immutable as $$
begin
  if coalesce(trim(p_prenom), '') = '' or coalesce(trim(p_nom), '') = '' or coalesce(trim(p_identifiant), '') = '' then
    return 'champs_vides';
  end if;
  if lower(trim(p_identifiant)) = 'admin' then return 'identifiant_reserve'; end if;
  if lower(trim(p_identifiant)) !~ '^[a-z]{2,30}$' then return 'identifiant_invalide'; end if;
  return null;
end $$;

create or replace function public.election_admin_ajouter(p_mdp text, p_identifiant text, p_prenom text, p_nom text)
returns json language plpgsql security definer set search_path = public as $$
declare v_id text := lower(trim(p_identifiant)); v_err text;
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  v_err := election_admin_controle(p_identifiant, p_prenom, p_nom);
  if v_err is not null then return json_build_object('ok', false, 'erreur', v_err); end if;
  if exists (select 1 from election_eleves where identifiant = v_id) then
    return json_build_object('ok', false, 'erreur', 'identifiant_pris');
  end if;
  insert into election_eleves (identifiant, prenom, nom) values (v_id, trim(p_prenom), upper(trim(p_nom)));
  return json_build_object('ok', true);
end $$;

create or replace function public.election_admin_modifier(p_mdp text, p_ancien text, p_identifiant text, p_prenom text, p_nom text)
returns json language plpgsql security definer set search_path = public as $$
declare v_id text := lower(trim(p_identifiant)); v_err text;
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  v_err := election_admin_controle(p_identifiant, p_prenom, p_nom);
  if v_err is not null then return json_build_object('ok', false, 'erreur', v_err); end if;
  if not exists (select 1 from election_eleves where identifiant = p_ancien) then
    return json_build_object('ok', false, 'erreur', 'introuvable');
  end if;
  if v_id <> p_ancien and exists (select 1 from election_eleves where identifiant = v_id) then
    return json_build_object('ok', false, 'erreur', 'identifiant_pris');
  end if;
  update election_eleves set identifiant = v_id, prenom = trim(p_prenom), nom = upper(trim(p_nom))
   where identifiant = p_ancien;   -- les bulletins suivent (on update cascade)
  return json_build_object('ok', true);
end $$;

-- Supprimer un élève : son bulletin disparaît ; les bulletins qui l'avaient
-- choisi sont annulés et leurs auteurs peuvent revoter.
create or replace function public.election_admin_supprimer(p_mdp text, p_identifiant text)
returns json language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  if not exists (select 1 from election_eleves where identifiant = p_identifiant) then
    return json_build_object('ok', false, 'erreur', 'introuvable');
  end if;
  with annules as (
    delete from election_bulletins
     where delegue = p_identifiant or suppleant = p_identifiant
    returning votant
  )
  update election_eleves set a_vote = false
   where identifiant in (select votant from annules where votant is not null)
     and identifiant <> p_identifiant;
  get diagnostics n = row_count;
  delete from election_bulletins where votant = p_identifiant;
  delete from election_eleves where identifiant = p_identifiant;
  return json_build_object('ok', true, 'a_revoter', n);
end $$;

-- Annuler le vote d'un élève : il peut revoter
create or replace function public.election_admin_reinitialiser_vote(p_mdp text, p_identifiant text)
returns json language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  if not exists (select 1 from election_eleves where identifiant = p_identifiant) then
    return json_build_object('ok', false, 'erreur', 'introuvable');
  end if;
  delete from election_bulletins where votant = p_identifiant;
  get diagnostics n = row_count;
  update election_eleves set a_vote = false where identifiant = p_identifiant;
  return json_build_object('ok', true, 'bulletin_trouve', n > 0);
end $$;

-- Tout remettre à zéro (garde la liste des élèves)
create or replace function public.election_admin_reinitialiser_tout(p_mdp text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not election_admin_ok(p_mdp) then return json_build_object('ok', false, 'erreur', 'acces_refuse'); end if;
  delete from election_bulletins where true;
  update election_eleves set a_vote = false where a_vote;
  return json_build_object('ok', true);
end $$;

-- 8. Droits ----------------------------------------------------------------
revoke execute on function public.election_admin_ok(text)                     from public, anon, authenticated;
revoke execute on function public.election_admin_controle(text, text, text)   from public, anon, authenticated;

grant execute on function public.election_liste()                              to anon, authenticated;
grant execute on function public.election_connexion(text)                      to anon, authenticated;
grant execute on function public.election_voter(text, text, text)              to anon, authenticated;
grant execute on function public.election_resultats()                          to anon, authenticated;
grant execute on function public.election_admin_verifier(text)                 to anon, authenticated;
grant execute on function public.election_admin_liste(text)                    to anon, authenticated;
grant execute on function public.election_admin_ajouter(text, text, text, text)            to anon, authenticated;
grant execute on function public.election_admin_modifier(text, text, text, text, text)     to anon, authenticated;
grant execute on function public.election_admin_supprimer(text, text)          to anon, authenticated;
grant execute on function public.election_admin_reinitialiser_vote(text, text) to anon, authenticated;
grant execute on function public.election_admin_reinitialiser_tout(text)       to anon, authenticated;

-- Changer le mot de passe admin plus tard sans relancer tout le script :
--   update election_config set valeur = extensions.crypt('NouveauMotDePasse', extensions.gen_salt('bf'))
--    where cle = 'mdp_admin';
