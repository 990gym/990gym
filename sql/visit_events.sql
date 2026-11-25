-- =====================================================================
-- 유입 기록 (어디서 들어와서 어디까지 갔나)
-- 홈페이지(track.js) → Edge Function 'track' → 이 표.
-- 개인정보 없음: 방문자마다 무작위 번호(visitor_id)만 저장.
-- 공개 키로는 읽지도 쓰지도 못한다(정책 없음). 서버(서비스 키)만 접근.
-- 여러 번 실행해도 안전합니다.
-- =====================================================================

create table if not exists public.visit_events (
  id bigint generated always as identity primary key,
  visitor_id text not null,
  stage text not null check (stage in ('visit', 'start', 'card', 'complete', 'fail', 'inquiry')),
  page text not null check (page in ('main', 'spinning')),
  source text not null default '직접 유입',
  medium text,
  campaign text,
  app text,
  created_at timestamptz not null default now()
);
comment on table public.visit_events is '홈페이지 유입 기록 — visit 방문 / start 신청 시작 / card 카드 등록으로 이동 / complete 결제 완료 / fail 실패 / inquiry 상담 신청. 회원 개인정보 저장 금지';

create index if not exists visit_events_created_at_idx on public.visit_events (created_at);
create index if not exists visit_events_visitor_idx on public.visit_events (visitor_id);

alter table public.visit_events enable row level security;

-- 유입경로별 집계 (사람 수 기준)
create or replace function public.visit_report(p_from timestamptz, p_page text default null)
returns table (source text, visits bigint, starts bigint, cards bigint, completes bigint, fails bigint, inquiries bigint)
language sql stable
set search_path = public
as $$
  select e.source,
    count(distinct e.visitor_id) filter (where e.stage = 'visit'),
    count(distinct e.visitor_id) filter (where e.stage = 'start'),
    count(distinct e.visitor_id) filter (where e.stage = 'card'),
    count(distinct e.visitor_id) filter (where e.stage = 'complete'),
    count(distinct e.visitor_id) filter (where e.stage = 'fail'),
    count(distinct e.visitor_id) filter (where e.stage = 'inquiry')
  from public.visit_events e
  where e.created_at >= p_from and (p_page is null or e.page = p_page)
  group by e.source
  order by 2 desc, 3 desc;
$$;

-- 최근 신청 시도 (시작한 사람마다 한 줄: 완료했는지, 어디서 멈췄는지)
create or replace function public.visit_recent(p_from timestamptz, p_page text default null, p_limit int default 40)
returns table (visitor text, source text, page text, app text, started_at timestamptz, completed boolean, last_stage text)
language sql stable
set search_path = public
as $$
  select right(e.visitor_id, 6),
    (array_agg(e.source order by e.created_at))[1],
    (array_agg(e.page order by e.created_at))[1],
    max(e.app),
    min(e.created_at),
    bool_or(e.stage = 'complete'),
    case when bool_or(e.stage = 'complete') then 'complete'
         when bool_or(e.stage = 'fail') then 'fail'
         when bool_or(e.stage = 'card') then 'card'
         else 'start' end
  from public.visit_events e
  where e.created_at >= p_from and (p_page is null or e.page = p_page)
    and e.stage in ('start', 'card', 'complete', 'fail')
  group by e.visitor_id
  order by 5 desc
  limit greatest(1, least(p_limit, 200));
$$;

revoke all on function public.visit_report(timestamptz, text) from public, anon, authenticated;
revoke all on function public.visit_recent(timestamptz, text, int) from public, anon, authenticated;
grant execute on function public.visit_report(timestamptz, text) to service_role;
grant execute on function public.visit_recent(timestamptz, text, int) to service_role;
