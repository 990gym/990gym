-- =====================================================================
-- 회원·상담 데이터 잠그기 (페이지 소스에 있는 공개 키로는 못 읽게)
--
-- 반드시 관리자 페이지가 서버(api/admin)를 거치도록 바뀐 "뒤에" 실행하세요.
-- 실행 후: 서버(Vercel)만 회원 정보를 읽고 고칠 수 있고,
--          홈페이지 상담 신청(넣기)만 공개로 허용됩니다.
-- 여러 번 실행해도 안전합니다.
-- =====================================================================

alter table public.subscribers enable row level security;
alter table public.inquiries enable row level security;
alter table public.subscription_events enable row level security;

do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in ('subscribers', 'inquiries', 'subscription_events')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

create policy "homepage can submit inquiries" on public.inquiries
  for insert to anon with check (true);
