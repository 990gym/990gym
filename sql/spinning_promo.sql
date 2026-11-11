-- =====================================================================
-- 스피닝 첫 달 50% 프로모션 + 정가 전환 동의 기록 칸
--
-- 사용법: Supabase 대시보드 → SQL Editor → New query → 붙여넣기 → Run
-- 여러 번 실행해도 안전합니다. 서버 새 버전을 올리기 "전에" 먼저 실행하세요.
--
-- promo            : 'spinning_half' 처럼 첫 달 할인으로 가입한 회원 표시 (일반 가입은 비어 있음)
-- price_consent_at : 손님이 '다음 달부터 정가 결제'에 동의한 시각. 비어 있으면 결제일에 결제 없이 자동 종료
-- consent_token    : 손님에게 보내는 동의 링크용 열쇠 (the990.co.kr/continue.html?t=...)
-- =====================================================================

alter table public.subscribers add column if not exists promo text;
alter table public.subscribers add column if not exists price_consent_at timestamptz;
alter table public.subscribers add column if not exists consent_token uuid not null default gen_random_uuid();
create unique index if not exists subscribers_consent_token_key on public.subscribers (consent_token);
