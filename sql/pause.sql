-- 쉬어가기(월구독 일시정지)
-- status = 'paused' 이면 결제 없이 쉬는 중. next_billing_date = 다시 시작(자동결제)하는 날.
-- 원래 결제일은 pause_from_date 에 남겨 둔다 (재시작일을 바꿀 때 허용 범위 7~90일의 기준).

alter table public.subscribers
  add column if not exists paused_at timestamptz,
  add column if not exists pause_from_date date,
  add column if not exists resume_msg_sent_at timestamptz;

-- 이력 표에 '쉬어가기' 기록 허용
alter table public.subscription_events drop constraint if exists subscription_events_event_type_check;
alter table public.subscription_events add constraint subscription_events_event_type_check
  check (event_type = any (array['signup','cancel','return','payment_failed','plan_change','pause']));

-- 이력 자동 기록 트리거: 쉬어가기 시작 / 재시작일 변경 / 쉬어가기 후 재시작
create or replace function public.log_subscription_event()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

    elsif new.status = 'paused' then
      insert into subscription_events (subscriber_id, event_type, plan, note)
      values (sid, 'pause', new.plan, to_char(new.next_billing_date, 'FMMM"월" FMDD"일"') || ' 재시작 예정');

    elsif new.status = 'active' then
      insert into subscription_events (subscriber_id, event_type, plan, from_plan, note)
      values (sid, 'return', new.plan,
              case when old.plan is distinct from new.plan then old.plan end,
              case when old.status = 'payment_failed' then '결제실패 후 재개'
                   when old.status = 'paused' then '쉬어가기 후 재시작'
                   when new.created_at is distinct from old.created_at then '홈페이지 재가입'
                   else '어드민 복구' end);
    end if;

  -- 상태는 그대로인데 플랜만 바뀜
  elsif new.plan is distinct from old.plan then
    insert into subscription_events (subscriber_id, event_type, plan, from_plan)
    values (sid, 'plan_change', new.plan, old.plan);
  end if;

  -- 쉬는 중에 재시작일을 바꾸면 가장 최근 쉬어가기 기록에 반영
  if new.status = 'paused' and old.status = 'paused' and new.next_billing_date is distinct from old.next_billing_date then
    update subscription_events
       set note = to_char(new.next_billing_date, 'FMMM"월" FMDD"일"') || ' 재시작 예정 (변경)'
     where id = (select id from subscription_events
                  where subscriber_id = sid and event_type = 'pause'
                  order by occurred_at desc, id desc limit 1);
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
$function$;
