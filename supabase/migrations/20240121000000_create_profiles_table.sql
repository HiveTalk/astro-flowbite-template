-- supabase/migrations/20240121000000_create_profiles_table.sql
create extension if not exists "uuid-ossp";

-- Create profiles table
create table profiles (
  id uuid primary key default uuid_generate_v4(),
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
  username text,
  lightning_address text,
  email text,
  nostr_pubkey text not null unique,
  avatar_url text,
  website_link text,
  subscriber_status boolean default false,
  lnbits_wallet_id text,
  lnbits_api_key text
);

-- Create indexes
create index idx_profiles_nostr_pubkey on profiles(nostr_pubkey);
create index idx_profiles_username on profiles(username);
create index idx_profiles_email on profiles(email);

-- Add row level security policies
alter table profiles enable row level security;

create policy "Public profiles are viewable by everyone"
  on profiles for select using (true);

create policy "Users can insert their own profile"
  on profiles for insert with check (auth.uid() = id);

create policy "Users can update their own profile"
  on profiles for update using (auth.uid() = id);

-- supabase/migrations/20240121000001_create_room_info_table.sql
-- Create room_info table
create table room_info (
  id uuid primary key default uuid_generate_v4(),
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
  room_name text not null,
  room_picture_url text,
  room_description text,
  room_owner uuid not null references profiles(id) on delete cascade,
  room_npub text not null,
  room_nsec text not null,
  room_nip05 text,
  room_lightning_address text,
  room_zap_goal bigint default 0,
  extra_room_mods uuid[], -- Array of profile UUIDs
  room_visibility boolean not null default true,
  room_nostr_acl_list text, -- Comma separated list
  save_chat_directive boolean not null default false,
  room_relay_url text,
  
  constraint fk_room_owner foreign key (room_owner) references profiles(id) on delete cascade
);

-- Create indexes
create index idx_room_info_owner on room_info(room_owner);
create index idx_room_info_name on room_info(room_name);
create index idx_room_info_npub on room_info(room_npub);
create index idx_room_info_visibility on room_info(room_visibility);

-- Create room moderators junction table
create table room_moderators (
  id uuid primary key default uuid_generate_v4(),
  room_id uuid not null references room_info(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  is_active boolean not null default true,
  
  constraint unique_room_moderator unique (room_id, profile_id)
);

-- Create indexes
create index idx_room_moderators_room on room_moderators(room_id);
create index idx_room_moderators_profile on room_moderators(profile_id);
create index idx_room_moderators_active on room_moderators(is_active);

-- Add RLS policies for room_info
alter table room_info enable row level security;

create policy "Public rooms are viewable by everyone"
  on room_info for select using (room_visibility = true);

create policy "Room owners can manage their rooms"
  on room_info for all using (auth.uid() = room_owner);

-- Add RLS policies for room_moderators
alter table room_moderators enable row level security;

create policy "Moderators are viewable by everyone"
  on room_moderators for select using (true);

create policy "Only room owners can manage moderators"
  on room_moderators for all using (
    auth.uid() in (
      select room_owner from room_info where id = room_id
    )
  );

-- Example functions for common operations
-- Function to add a moderator
create or replace function add_room_moderator(
  p_room_id uuid,
  p_profile_id uuid
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_moderator_id uuid;
begin
  -- Check if user is room owner
  if not exists (
    select 1 from room_info
    where id = p_room_id and room_owner = auth.uid()
  ) then
    raise exception 'Not authorized';
  end if;

  insert into room_moderators (room_id, profile_id)
  values (p_room_id, p_profile_id)
  returning id into v_moderator_id;

  return v_moderator_id;
end;
$$;

-- Function to get room with details
create or replace function get_room_with_details(p_room_id uuid)
returns json
language plpgsql
security definer
as $$
declare
  v_result json;
begin
  select json_build_object(
    'room', r,
    'owner', p,
    'moderators', (
      select json_agg(mp)
      from room_moderators rm
      join profiles mp on mp.id = rm.profile_id
      where rm.room_id = r.id and rm.is_active = true
    )
  ) into v_result
  from room_info r
  join profiles p on p.id = r.room_owner
  where r.id = p_room_id;

  return v_result;
end;
$$;