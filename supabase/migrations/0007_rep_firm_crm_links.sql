-- Rep firms are themselves Accounts in Dataverse: children of INTELLIMIX CORP.
-- (DBA AVL MEDIA GROUP) with Relationship Type = "Independent Rep Firm". This links
-- each rep_firms row to its real Dataverse accountid, so an account's rep firm can
-- be resolved directly via its parentaccountid -- more authoritative than the
-- state-matching fallback, which stays for accounts not under a rep firm parent.
--
-- Also expands rep_firms to the 12 "Independent Rep Firm" accounts actually found
-- in the CRM (5 more than the original 6 seeded firms). TBD Southeast has no
-- confirmed CRM match yet and stays unlinked; the 7 new firms have no confirmed
-- territory/states yet (AUDAC's public site has no rep/territory locator to check
-- against) -- both need following up with the business.

alter table public.rep_firms add column crm_account_external_id text unique;

comment on column public.rep_firms.crm_account_external_id is 'Dataverse accountid of this rep firm''s own Account record (child of Intellimix, Relationship Type = Independent Rep Firm) -- used to resolve an account''s rep firm directly via its parentaccountid, more authoritative than state matching';

update public.rep_firms set crm_account_external_id = 'a06beb2b-497a-f111-ab0e-7c1e52858921' where name = 'LVX';
update public.rep_firms set crm_account_external_id = '3bf5a159-bd7b-f111-ab0e-7c1e5273fdb9' where name = 'Mammoth';
update public.rep_firms set crm_account_external_id = 'dd44b12e-3921-f111-8341-7ced8d138d04' where name = 'MC Marketing Pro';
update public.rep_firms set crm_account_external_id = 'd6841075-be0e-f111-8406-6045bd95fa49' where name = 'DirectLink';
update public.rep_firms set crm_account_external_id = '7ff64475-40cb-ee11-9079-000d3a22ca0f' where name = 'Salesforce FL';

insert into public.rep_firms (name, territory, states, status, crm_account_external_id) values
  ('PAG Canada', 'Unknown — pending territory info', '{}', 'active', '0b796d3f-b880-ea11-a812-000d3a20f252'),
  ('Bormann Marketing North', 'Unknown — pending territory info', '{}', 'active', 'c08d3a12-0257-eb11-a812-000d3a21032d'),
  ('Industry Tech Sales', 'Unknown — pending territory info', '{}', 'active', '7622e692-08e0-f011-8544-000d3a45bd13'),
  ('C. L. Pugh & Associates', 'Unknown — pending territory info', '{}', 'active', '20b5fc0c-1709-ef11-9f89-000d3aacad03'),
  ('Lienau AV', 'Unknown — pending territory info', '{}', 'active', '456ef180-0e62-eb11-a812-000d3aae984f'),
  ('Eaton Sales Associates', 'Unknown — pending territory info', '{}', 'active', 'd2ad7854-c00d-f111-8406-6045bd9ca3b6'),
  ('Bormann Tola', 'Unknown — pending territory info', '{}', 'active', '89a4f66f-d011-f111-8406-6045bd9ca3b6');
