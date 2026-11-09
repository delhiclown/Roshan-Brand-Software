begin;

alter table public.products add column if not exists selling_price numeric(12, 2);
alter table public.products add column if not exists original_price numeric(12, 2);
alter table public.products add column if not exists rating numeric(3, 2) not null default 0;
alter table public.products add column if not exists review_count integer not null default 0;
alter table public.products add column if not exists sold_count integer not null default 0;
alter table public.products add column if not exists show_stats boolean not null default false;

update public.products
set selling_price = price
where selling_price is null;

alter table public.products alter column selling_price set default 0;
alter table public.products alter column selling_price set not null;
alter table public.products drop constraint if exists products_selling_price_nonnegative;
alter table public.products add constraint products_selling_price_nonnegative
  check (selling_price >= 0);
alter table public.products drop constraint if exists products_original_price_positive;
alter table public.products add constraint products_original_price_positive
  check (original_price is null or original_price > 0);
alter table public.products drop constraint if exists products_rating_range;
alter table public.products add constraint products_rating_range
  check (rating >= 0 and rating <= 5);
alter table public.products drop constraint if exists products_review_count_nonnegative;
alter table public.products add constraint products_review_count_nonnegative
  check (review_count >= 0);
alter table public.products drop constraint if exists products_sold_count_nonnegative;
alter table public.products add constraint products_sold_count_nonnegative
  check (sold_count >= 0);

commit;
