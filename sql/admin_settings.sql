-- =====================================================================
-- 관리자 비밀번호 저장 표 (관리자 화면에서 '비밀번호 변경'용)
-- 비밀번호 원문은 저장하지 않고 '해시'만 저장합니다. 서버만 읽을 수 있습니다.
-- 비밀번호를 잊었을 때: 아래 줄을 실행하면 Vercel 의 ADMIN_PASSWORD 로 다시 로그인됩니다.
--   delete from public.admin_settings where key = 'admin_password_hash';
-- 여러 번 실행해도 안전합니다.
-- =====================================================================
create table if not exists public.admin_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.admin_settings enable row level security;
