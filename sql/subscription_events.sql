-- =====================================================================
-- 990짐 구독 이력(가입·해지·복귀·플랜변경·결제실패) 자동 기록
--
-- 사용법: Supabase 대시보드 → SQL Editor → New query → 이 파일 전체 붙여넣기 → Run
-- 여러 번 실행해도 안전합니다 (이미 있으면 건너뜀).
--
-- 원리: subscribers 표가 바뀔 때마다 DB가 직접 subscription_events 에 한 줄씩 남깁니다.
--   · 홈페이지 가입(billing-confirm), 어드민 해지/복구(cancel-subscriber),
--     월 자동결제 실패(billing-charge), 플랜 변경 — 어느 경로로 바뀌든 다 잡힙니다.
--   · 서버 코드는 손대지 않아도 됩니다.
-- =====================================================================

begin;

-- 1) 이력 테이블 ------------------------------------------------------
create table if not exists public.subscription_events (
  id            bigserial primary key,
  subscriber_id text        not null,          -- subscribers.id (형식 상관없이 text로 보관)
  event_type    text        not null
                check (event_type in ('signup','cancel','return','payment_failed','plan_change')),
  occurred_at   timestamptz not null default now(),
  plan          text,                          -- 그 시점 플랜
  from_plan     text,                          -- 플랜 변경/복귀 시 이전 플랜
  reason        text,                          -- 해지 사유
  note          text,
  source        text        not null default 'live'   -- live = 자동 기록, backfill = 기존 데이터로 복원
);

create index if not exists subscription_events_sub_idx
  on public.subscription_events (subscriber_id, occurred_at);

-- 어드민 화면(anon 키)에서 읽기만 허용. 쓰기는 아래 트리거만 합니다.
alter table public.subscription_events enable row level security;
drop policy if exists "admin read events" on public.subscription_events;
create policy "admin read events" on public.subscription_events
  for select to anon, authenticated using (true);
grant select on public.subscription_events to anon, authenticated;


-- 2) 기존 데이터로 이력 복원 (아직 이력이 하나도 없는 회원만) ------------
--    ※ 예전에 해지했다가 복귀한 회원의 '과거 해지 기록'은 DB에 남아 있지 않아 복원되지 않습니다.
--    ※ 홈페이지로 재가입한 회원은 가입일이 재가입일로 덮어써져 있습니다.

-- 가입
insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, source)
select s.id::text, 'signup', coalesce(s.created_at, now()), s.plan, 'backfill'
from public.subscribers s
where not exists (select 1 from public.subscription_events e where e.subscriber_id = s.id::text);

-- 해지 (해지일이 기록된 회원)
insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, reason, source)
select s.id::text, 'cancel', s.cancelled_at, s.plan, s.churn_reason, 'backfill'
from public.subscribers s
where s.status = 'cancelled' and s.cancelled_at is not null
  and not exists (select 1 from public.subscription_events e
                  where e.subscriber_id = s.id::text and e.event_type <> 'signup');

-- 해지 (해지일 없이 상태만 해지인 예전 회원 → 날짜 미상으로 표시)
insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, reason, note, source)
select s.id::text, 'cancel', coalesce(s.created_at, now()), s.plan, s.churn_reason, '해지일 미상', 'backfill'
from public.subscribers s
where s.status = 'cancelled' and s.cancelled_at is null
  and not exists (select 1 from public.subscription_events e
                  where e.subscriber_id = s.id::text and e.event_type <> 'signup');

-- 결제실패 (자동결제는 결제일 오후 6시에 돌기 때문에 그 시각으로 기록)
insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, source)
select s.id::text, 'payment_failed',
       coalesce((s.next_billing_date::date + time '18:00') at time zone 'Asia/Seoul', now()),
       s.plan, 'backfill'
from public.subscribers s
where s.status = 'payment_failed'
  and not exists (select 1 from public.subscription_events e
                  where e.subscriber_id = s.id::text and e.event_type <> 'signup');


-- 3) 앞으로의 변경을 자동 기록하는 트리거 ------------------------------
create or replace function public.log_subscription_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sid text := new.id::text;
begin
  if tg_op = 'INSERT' then
    insert into subscription_events (subscriber_id, event_type, occurred_at, plan)
    values (sid, 'signup', coalesce(new.created_at, now()), new.plan);
    return new;
  end if;

  -- 상태 변화
  if new.status is distinct from old.status then
    if new.status = 'cancelled' then
      insert into subscription_events (subscriber_id, event_type, plan, reason)
      values (sid, 'cancel', new.plan, new.churn_reason);

    elsif new.status = 'payment_failed' then
      insert into subscription_events (subscriber_id, event_type, plan)
      values (sid, 'payment_failed', new.plan);

    elsif new.status = 'active' then
      insert into subscription_events (subscriber_id, event_type, plan, from_plan, note)
      values (sid, 'return', new.plan,
              case when old.plan is distinct from new.plan then old.plan end,
              case when old.status = 'payment_failed' then '결제실패 후 재개'
                   when new.created_at is distinct from old.created_at then '홈페이지 재가입'
                   else '어드민 복구' end);
    end if;

  -- 상태는 그대로인데 플랜만 바뀜
  elsif new.plan is distinct from old.plan then
    insert into subscription_events (subscriber_id, event_type, plan, from_plan)
    values (sid, 'plan_change', new.plan, old.plan);
  end if;

  -- 해지 후 이탈 사유를 입력/수정하면 가장 최근 해지 기록에 반영
  if new.status = 'cancelled' and new.churn_reason is distinct from old.churn_reason then
    update subscription_events
       set reason = new.churn_reason
     where id = (select id from subscription_events
                  where subscriber_id = sid and event_type = 'cancel'
                  order by occurred_at desc, id desc limit 1);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_log_subscription_event on public.subscribers;
create trigger trg_log_subscription_event
  after insert or update on public.subscribers
  for each row execute function public.log_subscription_event();

commit;
