// 990 유입 기록: 어디서 들어와서(유입경로) 어디까지 갔는지(방문 → 신청 시작 → 카드 등록 → 결제 완료)
// 이름·전화번호 같은 개인정보는 보내지 않는다. 방문자마다 무작위 번호 하나만 쓴다.
// 서버: Supabase Edge Function 'track' (srv/track-edge.ts), 표: public.visit_events
(function () {
  var EP = 'https://twwpxtveupsqwenkprdw.supabase.co/functions/v1/track';
  var KEY = 't990';
  var KEEP = 30 * 24 * 60 * 60 * 1000;   // 유입경로는 30일 동안 기억

  var params;
  try { params = new URLSearchParams(window.location.search); } catch (e) { params = { get: function () { return null; } }; }
  var page = /spinning/i.test(window.location.pathname) ? 'spinning' : 'main';
  // 토스 카드 등록을 마치고 돌아온 화면이면 유입경로를 새로 판단하지 않는다
  var isReturn = params.get('success') === '1' || params.get('fail') === '1' || !!params.get('code');

  function load() { try { return JSON.parse(localStorage.getItem(KEY) || 'null') || {}; } catch (e) { return {}; } }
  function save(s) { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (e) {} }

  var ua = navigator.userAgent || '';
  function inApp() {
    if (/Instagram/i.test(ua)) return '인스타그램 앱';
    if (/FBAN|FBAV|FB_IAB/i.test(ua)) return '페이스북 앱';
    if (/KAKAOTALK/i.test(ua)) return '카카오톡 앱';
    if (/NAVER\(inapp/i.test(ua)) return '네이버 앱';
    if (/Daangn|Karrot/i.test(ua)) return '당근 앱';
    return '';
  }

  function byName(s) {
    if (/naver/.test(s)) return '네이버';
    if (/daangn|karrot|danggeun|당근/.test(s)) return '당근';
    if (/kakao/.test(s)) return '카카오톡';
    if (/google/.test(s)) return '구글';
    if (/daum/.test(s)) return '다음';
    if (/youtube|youtu\.be/.test(s)) return '유튜브';
    return '';
  }

  // 유입경로 판단: 1) 링크 꼬리표(utm) 2) 직전 사이트 3) 앱 종류. 내부 이동이면 null
  function detect() {
    var us = (params.get('utm_source') || '').toLowerCase();
    var um = (params.get('utm_medium') || '').toLowerCase();
    if (us) {
      // 인포에 둔 센터 등록용 QR(?utm_source=center): 현장에서 안내받아 등록한 경우
      if (/^(center|desk|info|센터)$/.test(us)) return '센터 방문';
      if (/meta|facebook|^fb$|instagram|^ig$/.test(us)) {
        if (us === 'meta' || /paid|cpc|ad/.test(um)) return '메타 광고';
        return /insta|^ig$/.test(us) ? '인스타그램' : '페이스북';
      }
      return byName(us) || us.slice(0, 30);
    }
    var host = '';
    try { if (document.referrer) host = new URL(document.referrer).hostname.toLowerCase(); } catch (e) {}
    if (host) {
      if (/the990\.co\.kr$/.test(host) || /toss/.test(host)) return null;
      if (/instagram/.test(host)) return '인스타그램';
      if (/facebook|fb\.com/.test(host)) return '페이스북';
      return byName(host) || host.replace(/^www\./, '').slice(0, 30);
    }
    var app = inApp();
    if (app) return app.replace(' 앱', '');
    return '직접 유입';
  }

  var st = load();
  var urlVid = params.get('vid');
  if (!st.vid) st.vid = (urlVid && /^[a-z0-9]{8,40}$/.test(urlVid)) ? urlVid : 'v' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);

  if (!isReturn) {
    var d = detect();
    var stale = !st.src || !st.ts || Date.now() - st.ts > KEEP;
    // 바깥에서 새로 들어왔으면 그 경로로 바꾸고, 그냥 다시 연 경우(직접 유입)는 처음 경로를 유지
    if (d && (stale || d !== '직접 유입')) {
      st.src = d;
      st.med = (params.get('utm_medium') || '').slice(0, 30);
      st.camp = (params.get('utm_campaign') || '').slice(0, 60);
      st.ts = Date.now();
    }
  }
  save(st);

  function send(stage) {
    try {
      var body = JSON.stringify({ vid: st.vid, stage: stage, page: page, src: st.src || '', med: st.med || '', camp: st.camp || '', app: inApp() });
      // 토스로 넘어가기 직전에도 빠지지 않게 sendBeacon 우선
      if (navigator.sendBeacon && navigator.sendBeacon(EP, new Blob([body], { type: 'text/plain' }))) return;
      fetch(EP, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: body, keepalive: true }).catch(function () {});
    } catch (e) {}
  }

  window.t990 = send;
  window.t990vid = function () { return st.vid; };

  // 방문: 같은 창에서 페이지당 한 번만
  if (!isReturn) {
    var seen = false;
    try { seen = sessionStorage.getItem('t990v_' + page) === '1'; sessionStorage.setItem('t990v_' + page, '1'); } catch (e) {}
    if (!seen) send('visit');
  }
})();
