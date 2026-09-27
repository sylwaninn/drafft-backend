-- A third hold (20260926000003): the team asks the person for a selfie, to check that their photos are
-- really them. Its own migration: a new enum value can't be used in the transaction that adds it.
alter type public.moderation_state add value 'selfie';
