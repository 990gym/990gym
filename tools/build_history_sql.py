"""토스 결제내역 엑셀 → 회원별 구독 이력(subscription_events) 복원 SQL 생성.

사용: python3 -I build_history_sql.py <결제내역.xlsx> <출력.sql>

주문번호 규칙 (990gym-server):
  order-<timestamp>                 홈페이지 첫 결제(가입/재가입)  → 회원 id 없음, 이름·이메일 마스킹으로 연결
  order-<subscriber_id>-<ts>        월 자동결제
  order-restore-<subscriber_id>-<ts> 어드민 복구 결제
"""
import collections, datetime as dt, json, re, sys
import openpyxl

UUID = re.compile(r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
KST = dt.timezone(dt.timedelta(hours=9))
PLAN_BY_AMOUNT = {39000: '베이직', 69000: '스탠다드', 99000: '프리미엄'}
RESIGN_GAP_DAYS = 20   # 마지막 결제 후 이만큼 지나 다시 첫결제/복구결제가 오면 '복귀'로 본다


def plan_of(row):
    for p in ('베이직', '스탠다드', '프리미엄'):
        if p in (row['구매상품'] or ''):
            return p
    return PLAN_BY_AMOUNT.get(int(row['결제액'] or 0))


def kind_of(order):
    if order.startswith('order-restore-'):
        return 'restore'
    if re.fullmatch(r'order-\d+', order):
        return 'first'
    if UUID.search(order):
        return 'recurring'
    return None


def parse_ts(s):
    return dt.datetime.strptime(s, '%Y-%m-%d %H:%M:%S').replace(tzinfo=KST) if s else None


def add_month(t):
    y, m = (t.year + (t.month // 12), t.month % 12 + 1)
    import calendar
    d = min(t.day, calendar.monthrange(y, m)[1])
    return t.replace(year=y, month=m, day=d)


def load(path):
    ws = openpyxl.load_workbook(path).active
    head = [c.value for c in ws[1]]
    rows = []
    for r in ws.iter_rows(min_row=2, values_only=True):
        row = dict(zip(head, r))
        if not row.get('주문번호'):
            continue
        row['kind'] = kind_of(row['주문번호'])
        if not row['kind']:
            continue
        m = UUID.search(row['주문번호'])
        row['sid'] = m.group(1) if m else None
        row['paid_at'] = parse_ts(row['결제일시'])
        row['refund_at'] = parse_ts(row['취소완료일시'])
        row['plan'] = plan_of(row)
        row['mask'] = (row['구매자명'] or '', (row['구매자이메일'] or '').lower())
        rows.append(row)
    return rows


def group_people(rows):
    """회원 id 기준으로 결제를 묶고, id 없는 첫 결제는 같은 마스킹 이름·이메일의 id에 붙인다."""
    mask_ids = collections.defaultdict(set)
    first_tagged = {}
    for r in rows:
        if r['sid']:
            mask_ids[r['mask']].add(r['sid'])
            if r['sid'] not in first_tagged or r['paid_at'] < first_tagged[r['sid']]:
                first_tagged[r['sid']] = r['paid_at']
    people = collections.defaultdict(list)
    for r in rows:
        if r['sid']:
            key = ('id', r['sid'])
        else:
            ids = mask_ids.get(r['mask'], set())
            if len(ids) == 1:
                key = ('id', next(iter(ids)))
            elif len(ids) > 1:
                # 마스킹이 같은 회원이 여럿이면, 이 첫 결제 직후에 자동결제가 시작된 회원에게 붙인다
                after = [(first_tagged[i] - r['paid_at'], i) for i in ids if first_tagged[i] > r['paid_at']]
                key = ('id', min(after)[1]) if after else ('mask',) + r['mask']
            else:
                key = ('mask',) + r['mask']   # 자동결제 기록이 없는 회원 → DB에서 이름·이메일로 연결
        people[key].append(r)
    return people


def build_events(txs):
    """한 사람의 결제들로 이벤트 목록을 만든다."""
    txs = sorted(txs, key=lambda r: r['paid_at'])
    paid = [r for r in txs if r['결제상태'] == '완료']
    refunds = sorted((r for r in txs if r['결제상태'] == '취소' and r['refund_at']), key=lambda r: r['refund_at'])
    fails = [r for r in txs if r['결제상태'] == '결제실패' and r['kind'] == 'recurring']
    stream = sorted([('pay', r['paid_at'], r) for r in paid] + [('fail', r['paid_at'], r) for r in fails],
                    key=lambda x: x[1])

    ev = []
    active, stopped_by_fail, seen = False, False, False
    last_pay = last_plan = None

    def stop_estimate(until):
        """마지막 결제 이후 해지된 시점 추정: 그 사이 환불이 있으면 환불 시각, 아니면 결제 기간 종료일"""
        rf = [x['refund_at'] for x in refunds if last_pay < x['refund_at'] <= until]
        if rf:
            return rf[-1], '결제 취소(환불)'
        return min(add_month(last_pay), until - dt.timedelta(seconds=1)), '해지일 추정'

    for typ, t, r in stream:
        if typ == 'fail':
            if active:
                ev.append(dict(event_type='payment_failed', occurred_at=t, plan=last_plan, note=None))
                active, stopped_by_fail = False, True
            continue
        plan = r['plan'] or last_plan
        if not seen:
            if r['kind'] == 'first':
                ev.append(dict(event_type='signup', occurred_at=t, plan=plan, note=None))
            else:   # 첫 결제를 못 찾은 회원 → SQL에서 DB 가입일로 채움
                ev.append(dict(event_type='signup', occurred_at=t, plan=plan, note='__from_db'))
            active, seen = True, True
        else:
            gap = (t - last_pay).days
            is_return = (not active) or (r['kind'] in ('first', 'restore') and gap >= RESIGN_GAP_DAYS)
            if is_return:
                if active:   # 해지 기록 없이 다시 결제됨 → 그 사이 해지가 있었던 것
                    when, note = stop_estimate(t)
                    ev.append(dict(event_type='cancel', occurred_at=when, plan=last_plan, note=note))
                note = ('결제실패 후 재개' if stopped_by_fail and r['kind'] == 'restore'
                        else '어드민 복구' if r['kind'] == 'restore'
                        else '홈페이지 재가입' if r['kind'] == 'first' else '결제 재개')
                ev.append(dict(event_type='return', occurred_at=t, plan=plan,
                               from_plan=last_plan if plan != last_plan else None, note=note))
                active, stopped_by_fail = True, False
            elif plan != last_plan:
                ev.append(dict(event_type='plan_change', occurred_at=t, plan=plan, from_plan=last_plan,
                               note='결제 금액 기준'))
        last_pay, last_plan = t, plan

    if not seen:
        # 성공 결제가 하나도 없음 (전부 환불/실패) → 환불된 첫 결제가 있으면 가입 후 환불로 기록
        rf_first = [x for x in refunds if x['kind'] == 'first']
        if rf_first:
            x = rf_first[0]
            ev.append(dict(event_type='signup', occurred_at=x['paid_at'], plan=x['plan'], note=None))
            ev.append(dict(event_type='cancel', occurred_at=x['refund_at'], plan=x['plan'], note='결제 취소(환불)'))
        return ev, None

    end_at, end_note = stop_estimate(dt.datetime.max.replace(tzinfo=KST)) if active else (None, None)
    final = dict(active=active, last_pay=last_pay, end_at=end_at, end_note=end_note)
    return ev, final


def q(v):
    if v is None:
        return 'null'
    if isinstance(v, dt.datetime):
        return "'" + v.isoformat() + "'::timestamptz"
    if isinstance(v, bool):
        return 'true' if v else 'false'
    return "'" + str(v).replace("'", "''") + "'"


def main(src, out):
    rows = load(src)
    people = group_people(rows)
    ev_rows, end_rows = [], []
    for key, txs in people.items():
        sid = key[1] if key[0] == 'id' else None
        nm, em = (None, None) if sid else (key[1], key[2])
        events, final = build_events(txs)
        for e in events:
            ev_rows.append((sid, nm, em, e['event_type'], e['occurred_at'], e.get('plan'), e.get('from_plan'), e.get('note')))
        if final:
            end_rows.append((sid, nm, em, final['active'], final['last_pay'], final['end_at'], final['end_note']))

    def values(rs):
        return ',\n'.join('  (' + ', '.join(q(v) for v in r) + ')' for r in rs)

    sql = SQL_TEMPLATE.format(ev_values=values(ev_rows), end_values=values(end_rows),
                              n_tx=len(rows), n_people=len(people), n_ev=len(ev_rows))
    open(out, 'w').write(sql)
    c = collections.Counter(r[3] for r in ev_rows)
    print(json.dumps(dict(transactions=len(rows), people=len(people),
                          mask_only=sum(1 for k in people if k[0] == 'mask'), events=dict(c)), ensure_ascii=False))


SQL_TEMPLATE = r"""-- =====================================================================
-- 990짐 구독 과거 이력 복원 (토스 결제내역 2026-04-01 ~ 2026-11-09 기준)
--   결제 {n_tx}건 → {n_people}명 → 이벤트 {n_ev}건
--
-- 사용법: subscription_events.sql 을 먼저 한 번 실행한 뒤,
--         Supabase SQL Editor 에 이 파일 전체를 붙여넣고 Run.
--         여러 번 실행해도 안전합니다 (이전 복원분을 지우고 다시 넣음).
--
-- · 월 자동결제·복구결제의 주문번호에 회원 id가 들어 있어 그대로 연결합니다.
-- · 자동결제 기록이 없는 회원(첫 달에 해지 등)은 이름·이메일 마스킹(김*호 / ab****@naver.com)으로 연결합니다.
-- · 해지 날짜는 결제 기록에 남지 않아, '마지막 결제 기간이 끝난 날'로 추정합니다 (화면에 '무렵'으로 표시).
-- · 오늘 이후 자동으로 쌓인 기록(live)은 건드리지 않습니다.
-- =====================================================================

-- 작업용 임시 공간 (외부 API에 노출되지 않는 별도 스키마, 마지막에 삭제)
drop schema if exists toss_restore cascade;
create schema toss_restore;

create or replace function toss_restore.mask_name(n text) returns text language sql immutable as $$
  select case when n is null then null
              when char_length(btrim(n)) <= 1 then btrim(n)
              when char_length(btrim(n)) = 2 then left(btrim(n), 1) || '*'
              else left(btrim(n), 1) || repeat('*', char_length(btrim(n)) - 2) || right(btrim(n), 1) end $$;
create or replace function toss_restore.mask_email(e text) returns text language sql immutable as $$
  select case when e is null or position('@' in e) = 0 then null
              else lower(left(split_part(btrim(e), '@', 1), 2)
                         || repeat('*', greatest(char_length(split_part(btrim(e), '@', 1)) - 2, 0))
                         || '@' || split_part(btrim(e), '@', 2)) end $$;

create table toss_restore.ev (
  subscriber_id text, name_mask text, email_mask text,
  event_type text, occurred_at timestamptz, plan text, from_plan text, note text
);
insert into toss_restore.ev values
{ev_values};

create table toss_restore.ends (
  subscriber_id text, name_mask text, email_mask text,
  stream_active boolean, last_pay timestamptz, end_at timestamptz, end_note text
);
insert into toss_restore.ends values
{end_values};

-- 자동결제 기록이 없는 회원: 이름·이메일 마스킹이 정확히 한 명과 맞을 때만 연결
create table toss_restore.mask_map as
select k.name_mask, k.email_mask, min(s.id::text) as sid, count(*) as n
from (select distinct name_mask, email_mask from toss_restore.ev where subscriber_id is null) k
join public.subscribers s
  on toss_restore.mask_name(s.name) = k.name_mask and toss_restore.mask_email(s.email) = k.email_mask
group by 1, 2;

update toss_restore.ev t set subscriber_id = m.sid from toss_restore.mask_map m
 where t.subscriber_id is null and m.n = 1 and t.name_mask = m.name_mask and t.email_mask = m.email_mask;
update toss_restore.ends t set subscriber_id = m.sid from toss_restore.mask_map m
 where t.subscriber_id is null and m.n = 1 and t.name_mask = m.name_mask and t.email_mask = m.email_mask;

-- DB에 없는 회원(테스트 결제 등)은 버림
delete from toss_restore.ev  where subscriber_id is null or subscriber_id not in (select id::text from public.subscribers);
delete from toss_restore.ends where subscriber_id is null or subscriber_id not in (select id::text from public.subscribers);

-- 첫 결제를 못 찾은 회원의 가입일은 DB 가입일 사용 (자동결제 이전일 때만, 아니면 첫 자동결제 한 달 전으로 추정)
update toss_restore.ev t
   set occurred_at = case when s.created_at < t.occurred_at then s.created_at
                          else t.occurred_at - interval '1 month' end,
       note = case when s.created_at < t.occurred_at then null else '가입일 추정' end
  from public.subscribers s
 where t.note = '__from_db' and s.id::text = t.subscriber_id;

-- 이전에 넣은 임시 복원분 교체
delete from public.subscription_events
 where source in ('backfill', 'toss')
   and subscriber_id in (select distinct subscriber_id from toss_restore.ev);

insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, from_plan, note, source)
select t.subscriber_id, t.event_type, t.occurred_at, t.plan, t.from_plan, t.note, 'toss'
  from toss_restore.ev t
 where t.occurred_at < coalesce((select min(e.occurred_at) from public.subscription_events e
                                  where e.subscriber_id = t.subscriber_id and e.source = 'live'), now());

-- 마지막 결제 이후 해지된 회원: 해지 기록 추가 (DB의 이탈 사유를 붙임)
insert into public.subscription_events (subscriber_id, event_type, occurred_at, plan, reason, note, source)
select s.id::text, 'cancel',
       coalesce(s.cancelled_at, least(te.end_at, now())),
       s.plan, s.churn_reason,
       case when s.cancelled_at is null then te.end_note end,
       'toss'
  from public.subscribers s
  join toss_restore.ends te on te.subscriber_id = s.id::text
 where s.status = 'cancelled' and te.stream_active
   and not exists (select 1 from public.subscription_events e
                    where e.subscriber_id = s.id::text and e.event_type = 'cancel' and e.occurred_at > te.last_pay);

-- 마지막 해지 기록에 현재 이탈 사유 연결 (사유가 비어 있을 때만)
update public.subscription_events e set reason = s.churn_reason
  from public.subscribers s
 where s.status = 'cancelled' and s.churn_reason is not null and e.reason is null
   and e.subscriber_id = s.id::text and e.event_type = 'cancel'
   and e.id = (select id from public.subscription_events x
                where x.subscriber_id = s.id::text and x.event_type = 'cancel'
                order by occurred_at desc, id desc limit 1);

drop schema toss_restore cascade;

-- 결과 요약
select (select count(distinct subscriber_id) from public.subscription_events where source = 'toss') as "복원된 회원 수",
       (select count(*) from public.subscription_events where source = 'toss') as "복원된 기록 수",
       (select count(*) from public.subscribers s where not exists
          (select 1 from public.subscription_events e where e.subscriber_id = s.id::text and e.source = 'toss')) as "결제내역에 없어 기존 기록 유지";
"""

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
