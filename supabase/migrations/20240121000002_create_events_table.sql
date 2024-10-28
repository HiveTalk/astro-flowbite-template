-- supabase/migrations/20240121000002_create_events_table.sql

-- Create events table
create table events (
    id uuid primary key default uuid_generate_v4(),
    created_at timestamp with time zone default timezone('utc'::text, now()) not null,
    updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
    room_id uuid not null references room_info(id) on delete cascade,
    creator_id uuid not null references profiles(id) on delete cascade,
    nevent_id text not null unique,
    name text not null,
    description text,
    image_url text,
    start_time timestamp with time zone not null,
    end_time timestamp with time zone not null,
    is_paid_event boolean not null default false,
    ticket_price bigint, -- In satoshis, nullable for free events
    lightning_address text, -- Added lightning address field
    
    constraint valid_time_range check (end_time > start_time),
    constraint valid_ticket_price check (
        (is_paid_event = false and ticket_price is null) or
        (is_paid_event = true and ticket_price > 0)
    ),
    -- Add constraint to ensure paid events have a lightning address
    constraint valid_lightning_address check (
        (is_paid_event = false) or
        (is_paid_event = true and lightning_address is not null)
    ),
    constraint fk_room foreign key (room_id) references room_info(id) on delete cascade,
    constraint fk_creator foreign key (creator_id) references profiles(id) on delete cascade
);

-- Create indexes
create index idx_events_room on events(room_id);
create index idx_events_creator on events(creator_id);
create index idx_events_nevent on events(nevent_id);
create index idx_events_start_time on events(start_time);
create index idx_events_paid on events(is_paid_event);
create index idx_events_lightning_address on events(lightning_address); -- Added index for lightning address

-- Enable RLS
alter table events enable row level security;

-- RLS Policies
create policy "Events are viewable by everyone"
    on events for select using (true);

create policy "Room moderators can create events"
    on events for insert with check (
        exists (
            select 1 from room_moderators
            where room_id = events.room_id
            and profile_id = auth.uid()
            and is_active = true
        ) or
        exists (
            select 1 from room_info
            where id = events.room_id
            and room_owner = auth.uid()
        )
    );

create policy "Room moderators can update events"
    on events for update using (
        exists (
            select 1 from room_moderators
            where room_id = events.room_id
            and profile_id = auth.uid()
            and is_active = true
        ) or
        exists (
            select 1 from room_info
            where id = events.room_id
            and room_owner = auth.uid()
        )
    );

create policy "Room moderators can delete events"
    on events for delete using (
        exists (
            select 1 from room_moderators
            where room_id = events.room_id
            and profile_id = auth.uid()
            and is_active = true
        ) or
        exists (
            select 1 from room_info
            where id = events.room_id
            and room_owner = auth.uid()
        )
    );

-- Updated helper function to create an event
create or replace function create_room_event(
    p_room_id uuid,
    p_name text,
    p_description text,
    p_start_time timestamp with time zone,
    p_end_time timestamp with time zone,
    p_nevent_id text,
    p_is_paid_event boolean default false,
    p_ticket_price bigint default null,
    p_image_url text default null,
    p_lightning_address text default null -- Added lightning address parameter
)
returns uuid
language plpgsql
security definer
as $$
declare
    v_event_id uuid;
begin
    -- Check if user is room moderator or owner
    if not exists (
        select 1 from room_moderators
        where room_id = p_room_id
        and profile_id = auth.uid()
        and is_active = true
    ) and not exists (
        select 1 from room_info
        where id = p_room_id
        and room_owner = auth.uid()
    ) then
        raise exception 'Not authorized to create events in this room';
    end if;

    -- Validate lightning address for paid events
    if p_is_paid_event = true and p_lightning_address is null then
        raise exception 'Paid events must have a lightning address';
    end if;

    insert into events (
        room_id,
        creator_id,
        name,
        description,
        start_time,
        end_time,
        is_paid_event,
        ticket_price,
        image_url,
        nevent_id,
        lightning_address
    )
    values (
        p_room_id,
        auth.uid(),
        p_name,
        p_description,
        p_start_time,
        p_end_time,
        p_is_paid_event,
        p_ticket_price,
        p_image_url,
        p_nevent_id,
        p_lightning_address
    )
    returning id into v_event_id;

    return v_event_id;
end;
$$;

-- Helper function to get event details
create or replace function get_event_with_details(p_event_id uuid)
returns json
language plpgsql
security definer
as $$
declare
    v_result json;
begin
    select json_build_object(
        'event', e,
        'room', r,
        'creator', p
    ) into v_result
    from events e
    join room_info r on r.id = e.room_id
    join profiles p on p.id = e.creator_id
    where e.id = p_event_id;

    return v_result;
end;
$$;