(function () {
'use strict';

const ENGINE_FALLBACK = '/data/adb/modules/fbo_plus/fbo.sh';
const STATE_DIR = '/data/adb/fbo_plus';
const STATE_FILE = STATE_DIR + '/state.json';
const TRACE_FILE = '/data/local/tmp/fbo_webui.log';

const $ = (id) => document.getElementById(id);
const state = {
    engine: ENGINE_FALLBACK,
    probe: null,
    eta: { minutes: [2, 5, 8, 12, 15, 20, 25, 30], cap: 30, timeoutStep: 3 },
    apps: [], picked: new Set(), running: false,
};

/* ---------- 桥接：转义 + 返回值归一化 ---------- */
function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

function normalize(r) {
    if (r == null) return { code: -1, out: '', err: '' };
    if (typeof r === 'string') return { code: 0, out: r, err: '' };
    return {
        code: r.errno != null ? r.errno : (r.code != null ? r.code : 0),
        out: r.stdout || r.out || '',
        err: r.stderr || r.err || '',
    };
}

function bridge() { return (typeof globalThis.ksu !== 'undefined' && globalThis.ksu) || null; }

async function exec(argv, timeoutMs) {
    const k = bridge();
    if (!k || typeof k.exec !== 'function') return { code: -1, out: '', err: 'no ksu.exec' };
    const TIMEOUT = {};
    try {
        const r = await Promise.race([
            Promise.resolve(k.exec(argv.map(shq).join(' '))),
            new Promise((res) => setTimeout(() => res(TIMEOUT), timeoutMs || 15000)),
        ]);
        return r === TIMEOUT ? { code: -2, out: '', err: 'timeout' } : normalize(r);
    } catch (e) {
        return { code: -1, out: '', err: String((e && e.message) || e) };
    }
}

function trace(...parts) {
    try {
        const text = (new Date().toISOString().slice(11, 19) + ' ' + parts.join(' '))
            .replace(/[;&|`$\\{}"'<>]/g, '');
        exec(['sh', '-c', 'echo ' + shq(text) + ' >> ' + shq(TRACE_FILE)], 5000);
    } catch (e) {}
}

async function scriptLines(args, timeoutMs) {
    const r = await exec(['sh', state.engine, ...args], timeoutMs);
    const events = [];
    for (const line of (r.out || '').split('\n')) {
        const t = line.trim();
        if (!t) continue;
        try { events.push(JSON.parse(t)); } catch (e) {}
    }
    return { code: r.code, err: r.err, out: r.out, events };
}

/* ---------- 探测 / 应用 ---------- */
function setChip(text, tone) {
    const c = $('chip');
    c.textContent = text;
    c.className = 'chip' + (tone ? ' ' + tone : '');
}

async function resolveEngine() {
    const ids = [];
    try {
        if (globalThis.ksu && typeof globalThis.ksu.moduleInfo === 'function') {
            const id = globalThis.ksu.moduleInfo();
            if (id) ids.push(String(id));
        }
    } catch (e) {}
    ids.push('fbo_plus');
    for (const id of ids) {
        const p = `/data/adb/modules/${id}/fbo.sh`;
        const r = await exec(['sh', '-c', `[ -f ${shq(p)} ] && echo ok`]);
        if (r.out.indexOf('ok') >= 0) { state.engine = p; return; }
    }
    // 通配符必须留给 shell 展开，不能再被 shq 包起来
    const found = await exec(['sh', '-c', 'ls -d /data/adb/modules/*/fbo.sh 2>/dev/null']);
    const hit = ((found.out || '').match(/\/[^\s]*fbo\.sh/) || [])[0];
    if (hit) state.engine = hit;
}

async function probe() {
    const r = await scriptLines(['probe'], 20000);
    let p = null;
    for (const ev of r.events) if (ev.ev === 'probe') p = ev.data;
    trace('PROBE', r.code, r.events.length);
    return p;
}

function applyProbe(p) {
    const fail = (chip, reason) => { setChip(chip, 'bad'); $('bigLabel').textContent = reason; return false; };
    if (!p) return fail('无法检测', '探测失败');
    if (p.miui && p.miui.eta) state.eta = p.miui.eta;
    if (!p.miui.service) return fail('不支持', '系统里没有 miui.fbo.service');
    if (p.miui.center !== 'ok') return fail('缺少依赖', '手机管家未安装或不可用');
    if (p.miui.support !== 1) return fail('已禁用', '系统策略禁用了焕新存储');
    setChip('可用', 'ok');
    return true;
}

async function loadApps() {
    const r = await scriptLines(['apps'], 60000);
    for (const ev of r.events) if (ev.ev === 'apps' && Array.isArray(ev.data)) state.apps = ev.data;
    state.picked.clear();
    state.apps.slice(0, 3).forEach((a) => state.picked.add(a.pkg));
    renderApps(); updatePicked();
}

function renderApps() {
    const box = $('applist');
    box.textContent = '';
    for (const a of state.apps) {
        const label = document.createElement('label');
        label.className = 'appitem';
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = state.picked.has(a.pkg);
        cb.addEventListener('change', () => {
            cb.checked ? state.picked.add(a.pkg) : state.picked.delete(a.pkg);
            updatePicked();
        });
        const name = document.createElement('span');
        name.className = 'pkg';
        name.textContent = a.pkg;
        label.append(cb, name);
        box.append(label);
    }
}

function updatePicked() {
    const open = !$('applist').hidden;
    $('toggleList').textContent = `${open ? '收起' : '选择应用'} · 已选 ${state.picked.size} 个`;
    $('runBtn').disabled = state.running || state.picked.size === 0;
}

/* ---------- ETA：只消费 probe 参数 ---------- */
function estimateMinutes(n) {
    if (n <= 0) return 0;
    return n <= 8 ? state.eta.minutes[n - 1] : state.eta.cap;
}
function isOpenEnded(n) { return n > 8; }
// 硬超时由脚本按同一份 ETA 参数计算，页面只负责轮询上限
function timeoutFor(n) {
    const base = n <= 8 ? state.eta.minutes[n - 1] : state.eta.cap + (n - 8) * state.eta.timeoutStep;
    return base * 60 + 120;
}

/* ---------- 运行：后台化 + 轮询 ---------- */
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function reasonText(r) {
    switch (r) {
        case 'busy': return '已有整理在进行';
        case 'timeout': return '等待超时';
        case 'no-service': return '系统服务缺失';
        case 'center': return '手机管家不可用';
        case 'disabled': return '系统策略已禁用';
        case 'empty': return '应用列表为空';
        case 'service': return '无法启动 fbo-installd';
        case 'placeholder': return '手机管家未被识别';
        case 'policy': return '系统策略拒绝';
        case 'partial': return '部分应用未被处理';
        case 'aborted': return '系统未处理该应用';
        case 'crash': return 'FboNativeService 崩溃';
        default: return r || '未知原因';
    }
}

async function readState() {
    const r = await exec(['cat', STATE_FILE], 8000);
    try { return JSON.parse((r.out || '').trim()); } catch (e) { return null; }
}

async function readFile(rel, tailN) {
    const path = STATE_DIR + '/' + rel;
    const r = await exec(tailN ? ['tail', '-n', String(tailN), path] : ['cat', path], 15000);
    return r.out || '';
}

function renderProgress(s, t0) {
    const el = Math.max(0, ((Date.now() - t0) / 1000) | 0);
    const eta = s.openEnded ? '30 分钟以上' : (s.etaMinutes || 0) + ' 分钟';
    $('bigLabel').textContent = el + 's · 预计 ' + eta + ' · ' + s.done + '/' + s.total;
}

/* setsid + 断开 stdin/stdout：ksu.exec 只等外层 shell，立即返回 */
async function launchRun(runid, apps, timeout) {
    const bg = 'sh ' + shq(state.engine) + ' run --apps ' + shq(apps) +
        ' --runid ' + runid + ' --timeout ' + timeout +
        ' >> ' + shq(STATE_DIR + '/run.log') + ' 2>&1';
    const cmd = 'SET=""; command -v setsid >/dev/null 2>&1 && SET=setsid; ( $SET ' +
        bg + ' ) </dev/null >/dev/null 2>&1 &';
    const r = await exec(['sh', '-c', cmd], 10000);
    trace('BG', r.code, r.err);
    // -2 = 等满 10 秒：说明桥接在等后台进程，但它已经在跑了，继续轮询即可
    return r.code === 0 || r.code === -2;
}

async function startRun() {
    if (state.running || !state.picked.size) return;
    state.running = true; updatePicked();

    const runid = Date.now();
    const n = state.picked.size;
    const apps = [...state.picked].join(',');
    const timeout = timeoutFor(n);
    const etaText = isOpenEnded(n) ? '30 分钟以上' : estimateMinutes(n) + ' 分钟';
    setChip('运行中 · 预计 ' + etaText, 'busy');
    $('bigLabel').textContent = '0s · 预计 ' + etaText + ' · 0/' + n;

    if (!(await launchRun(runid, apps, timeout))) {
        state.running = false; updatePicked();
        setChip('启动失败', 'bad');
        $('bigLabel').textContent = '后台进程没能启动，请打开运行日志';
        return;
    }
    await finalizeRun(runid, timeout);
}

async function finalizeRun(runid, timeoutSec, startedMs) {
    // state.json 是唯一事实源：running=false 即本轮结束，ok/reason 由脚本判定
    const s = await pollState(runid, timeoutSec, startedMs);
    const finished = s && s.running === false;
    const ok = !!(s && s.ok === true);

    setChip(finished ? (ok ? '完成' : '失败') : '已中断', finished && ok ? 'ok' : 'bad');
    state.running = false; updatePicked();
    await loadStats(); refreshDiag();

    if (finished) {
        const elapsed = Math.max(0, (Number(s.updated) || 0) - (Number(s.started) || 0));
        $('bigLabel').textContent = ok
            ? elapsed + 's · 处理 ' + s.done + '/' + s.total
            : '失败：' + reasonText(s.reason || '');
    } else if (s && s.running === true) {
        $('bigLabel').textContent = '进度长时间没有更新，整理可能被系统终止';
    } else {
        $('bigLabel').textContent = '没有收到完成信号，请查看运行日志';
    }
}

async function pollState(runid, timeoutSec, startedMs) {
    const now0 = Date.now();
    let t0 = startedMs || 0;
    const limit = (timeoutSec + 180) * 1000;
    let lastUpdated = 0, stale = 0, matched = false;
    while (Date.now() - now0 < limit) {
        const s = await readState();
        if (s && s.runId === runid) {
            matched = true;
            if (!t0) t0 = (Number(s.started) || Math.floor(Date.now() / 1000)) * 1000;
            renderProgress(s, t0);
            if (s.running === false) return s;
            stale = (s.updated === lastUpdated) ? stale + 1 : 0;
            lastUpdated = s.updated;
            if (stale > 60) { trace('STALE'); return s; }
        } else if (!matched && Date.now() - now0 > 8000) {
            trace('NO STATE', runid);
            return null;
        }
        await sleep(2000);
    }
    trace('POLL TIMEOUT');
    return null;
}

/* 页面重载 / 重新打开时，引擎可能还在跑：接着跟踪同一次 runId */
async function resumeActiveRun() {
    const s = await readState();
    if (!s || s.running !== true || !s.runId) return;
    const age = Math.floor(Date.now() / 1000) - (Number(s.updated) || 0);
    if (age > 120) { trace('STALE STATE', s.runId); return; }
    state.running = true; updatePicked();
    setChip('运行中 · 继续跟踪', 'busy');
    const t0 = (Number(s.started) || Math.floor(Date.now() / 1000)) * 1000;
    renderProgress(s, t0);
    await finalizeRun(s.runId, timeoutFor(Number(s.total) || 1), t0);
}

/* ---------- 历史 ---------- */
function dayKey(ts) {
    const d = new Date(ts * 1000);
    return `${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function niceMax(v) {
    if (v <= 0) return 100;
    const mag = Math.pow(10, Math.floor(Math.log10(v)));
    return Math.ceil(v / (mag / 2)) * (mag / 2);
}
function parseHistory(text) {
    const out = [];
    for (const line of (text || '').split('\n')) {
        const t = line.trim(); if (!t) continue;
        try { const d = JSON.parse(t); if (d && d.ts) out.push(d); } catch (e) {}
    }
    return out;
}

async function loadStats() {
    const r = await scriptLines(['stats'], 15000);
    let items = [];
    for (const ev of r.events) if (ev.ev === 'stats' && Array.isArray(ev.data)) items = ev.data;

    if (!items.length) {
        const agg = new Map();
        for (const e of parseHistory(await readFile('history.jsonl'))) {
            if (!e.ok) continue;                          // 失败条目不进图表
            const k = dayKey(e.ts);
            agg.set(k, (agg.get(k) || 0) + (Number(e.removed) || 0));
        }
        items = [...agg.entries()].map(([day, count]) => ({ day, count }));
    }
    renderStats(items);
}

function renderStats(items) {
    const bars = $('bars'), xaxis = $('xaxis'), yticks = $('yticks'), grid = $('grid');
    bars.textContent = ''; xaxis.textContent = ''; yticks.textContent = ''; grid.textContent = '';

    const days = items.map((it) => ({
        day: it.day || dayKey(it.ts / 1000),
        count: Number(it.count) || 0,
    })).sort((a, b) => a.day.localeCompare(b.day)).slice(-7);

    if (!days.length) {
        $('total').textContent = '0';
        return;
    }
    const max = niceMax(Math.max(...days.map((d) => d.count)));
    const today = days[days.length - 1];
    $('total').textContent = String(today.count);
    $('bigLabel').textContent = `${today.day} 已处理碎片数量`;

    for (let i = 0; i <= 4; i++) {
        grid.append(document.createElement('i'));
        const tick = document.createElement('span');
        tick.textContent = String(Math.round(max - (max / 4) * i));
        yticks.append(tick);
    }
    for (const d of days) {
        const col = document.createElement('div');
        col.className = 'col';
        const bar = document.createElement('i');
        bar.className = 'bar';
        bar.style.height = `${max ? Math.max(2, (d.count / max) * 100) : 2}%`;
        col.append(bar); bars.append(col);
        const label = document.createElement('span');
        label.textContent = d.day;
        xaxis.append(label);
    }
}

async function refreshDiag() {
    const log = await readFile('run.log', 50);
    $('diag').textContent = log ? log.slice(-4000) : '暂无日志';
}

/* ---------- 启动 ---------- */
(async function init() {
    try {
        trace('BOOT', typeof globalThis.ksu, typeof (globalThis.ksu && globalThis.ksu.exec));
        if (!bridge()) { setChip('无桥接', 'bad'); return; }
        await resolveEngine();
        state.probe = await probe();
        // 先画历史，再让 applyProbe 的失败原因覆盖大标签
        await loadStats();
        if (applyProbe(state.probe)) {
            $('toggleList').textContent = '正在统计应用体积…';
            await loadApps();
        }
        refreshDiag();
        $('toggleList').addEventListener('click', () => {
            const box = $('applist');
            box.hidden = !box.hidden;
            updatePicked();
        });
        $('runBtn').addEventListener('click', startRun);
        resumeActiveRun().catch(() => {});
    } catch (e) {
        trace('INIT FAIL', String((e && e.message) || e).slice(0, 120));
        setChip('异常', 'bad');
    }
})();
})();