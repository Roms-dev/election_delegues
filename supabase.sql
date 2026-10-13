-- =====================================================================
--  Élection des délégués : à coller dans Supabase > SQL Editor > Run
--  Le script peut être relancé sans risque (il ne supprime aucun vote).
-- =====================================================================

create extension if not exists pgcrypto;

-- 1. Liste des élèves (identifiant = prénom en minuscules, sans accent)
create table if not exists public.election_eleves (
  identifiant text primary key,
  prenom      text not null,
  nom         text not null,
  a_vote      boolean not null default false
);

-- 2. Bulletins : AUCUN lien avec le votant -> le vote reste secret
create table if not exists public.election_bulletins (
  id        uuid primary key default gen_random_uuid(),
  delegue   text not null references public.election_eleves(identifiant),
  suppleant text not null references public.election_eleves(identifiant),
  constraint candidats_differents check (delegue <> suppleant)
);

-- 3. Personne ne peut lire ni écrire les tables directement depuis le site :
--    tout passe par les fonctions ci-dessous.
alter table public.election_eleves    enable row level security;
alter table public.election_bulletins enable row level security;
revoke all on public.election_eleves, public.election_bulletins from anon, authenticated;

-- 4. Les 31 élèves (relevés sur le mail groupé, à vérifier)
--    Deux "Marie" dans la classe : identifiants MarieG et MarieR.
insert into public.election_eleves (identifiant, prenom, nom) values
  ('aya',          'Aya',          'ABBES'),
  ('zainab',       'Zainab',       'ABOUMEJD'),
  ('omayma',       'Omayma',       'AITY'),
  ('romain',       'Romain',       'BERTRAND'),
  ('anais',        'Anais',        'BESIN'),
  ('nais',         'Nais',         'BOUISSEREN'),
  ('ikhlas',       'Ikhlas',       'BOUKHAMSA'),
  ('ambre',        'Ambre',        'CAMILLERI'),
  ('livia',        'Livia',        'CHARBONNIER'),
  ('isane',        'Isane',        'CHAUMEIX'),
  ('margot',       'Margot',       'CHEZE'),
  ('abderrahmane', 'Abderrahmane', 'EL BAZZARY'),
  ('inass',        'Inass',        'ELHAKIMI'),
  ('manon',        'Manon',        'FABRE'),
  ('alexia',       'Alexia',       'FAUBLADIER'),
  ('marieg',       'Marie',        'GASTAL'),
  ('nada',         'Nada',         'HANAN'),
  ('pierre',       'Pierre',       'KANDA'),
  ('adnane',       'Adnane',       'KOUNA'),
  ('branss',       'Branss',       'MANZALA KUMBI'),
  ('jessica',      'Jessica',      'MILLET'),
  ('alisson',      'Alisson',      'PORTEFAIX'),
  ('marier',       'Marie',        'RIGAUD'),
  ('leopoldine',   'Leopoldine',   'SAURON-VAN HILLE'),
  ('arthur',       'Arthur',       'SNASNI'),
  ('lea',          'Lea',          'TAVARES'),
  ('camille',      'Camille',      'THIOLIERE'),
  ('prune',        'Prune',        'TOURNEBIZE'),
  ('morgane',      'Morgane',      'VEERAMOOTOO'),
  ('jephthe',      'Jephthe',      'YUMA ABASSI'),
  ('haroun',       'Haroun',       'ZINE')
on conflict (identifiant) do update
  set prenom = excluded.prenom, nom = excluded.nom;

-- 5. Fonctions appelées par le site --------------------------------------

-- Liste des candidats (toute la classe)
create or replace function public.election_liste()
returns table (identifiant text, prenom text, nom text)
language sql stable security definer set search_path = public as $$
  select identifiant, prenom, nom from election_eleves order by nom, prenom;
$$;

-- Connexion avec le prénom
create or replace function public.election_connexion(p_identifiant text)
returns json
language plpgsql security definer set search_path = public as $$
declare e election_eleves;
begin
  select * into e from election_eleves where identifiant = lower(trim(p_identifiant));
  if not found then
    return json_build_object('ok', false, 'erreur', 'identifiant_inconnu');
  end if;
  return json_build_object('ok', true, 'identifiant', e.identifiant,
                           'prenom', e.prenom, 'nom', e.nom, 'a_vote', e.a_vote);
end $$;

-- Vote : une seule fois, vérifié côté serveur (verrou sur la ligne du votant)
create or replace function public.election_voter(p_votant text, p_delegue text, p_suppleant text)
returns json
language plpgsql security definer set search_path = public as $$
declare e election_eleves;
begin
  select * into e from election_eleves
   where identifiant = lower(trim(p_votant)) for update;
  if not found then
    return json_build_object('ok', false, 'erreur', 'identifiant_inconnu');
  end if;
  if e.a_vote then
    return json_build_object('ok', false, 'erreur', 'deja_vote');
  end if;
  if p_delegue is null or p_suppleant is null or p_delegue = p_suppleant then
    return json_build_object('ok', false, 'erreur', 'choix_invalide');
  end if;
  if not exists (select 1 from election_eleves where identifiant = p_delegue)
     or not exists (select 1 from election_eleves where identifiant = p_suppleant) then
    return json_build_object('ok', false, 'erreur', 'candidat_inconnu');
  end if;

  insert into election_bulletins (delegue, suppleant) values (p_delegue, p_suppleant);
  update election_eleves set a_vote = true where identifiant = e.identifiant;
  return json_build_object('ok', true);
end $$;

-- Résultats en direct : participation + 3 premiers de chaque scrutin
create or replace function public.election_resultats()
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'inscrits', (select count(*) from election_eleves),
    'votants',  (select count(*) from election_eleves where a_vote),
    'delegue', coalesce((
      select json_agg(t order by t.voix desc, t.nom, t.prenom) from (
        select e.identifiant, e.prenom, e.nom, count(*)::int as voix
          from election_bulletins b join election_eleves e on e.identifiant = b.delegue
         group by e.identifiant, e.prenom, e.nom
         order by voix desc, e.nom, e.prenom
         limit 3) t), '[]'::json),
    'suppleant', coalesce((
      select json_agg(t order by t.voix desc, t.nom, t.prenom) from (
        select e.identifiant, e.prenom, e.nom, count(*)::int as voix
          from election_bulletins b join election_eleves e on e.identifiant = b.suppleant
         group by e.identifiant, e.prenom, e.nom
         order by voix desc, e.nom, e.prenom
         limit 3) t), '[]'::json)
  );
$$;

grant execute on function public.election_liste()                     to anon, authenticated;
grant execute on function public.election_connexion(text)             to anon, authenticated;
grant execute on function public.election_voter(text, text, text)     to anon, authenticated;
grant execute on function public.election_resultats()                 to anon, authenticated;

-- =====================================================================
--  Requêtes utiles (à lancer à la main, une par une, si besoin)
-- =====================================================================
-- Qui n'a pas encore voté :
--   select prenom, nom from election_eleves where not a_vote order by nom;
--
-- Dépouillement complet (toutes les voix, pas seulement le top 3) :
--   select e.prenom, e.nom, count(*) as voix from election_bulletins b
--     join election_eleves e on e.identifiant = b.delegue
--    group by 1, 2 order by voix desc;
--   (remplace b.delegue par b.suppleant pour le second scrutin)
--
-- Remettre l'élection à zéro (après tes tests, avant le vrai vote) :
--   truncate election_bulletins;
--   update election_eleves set a_vote = false;
