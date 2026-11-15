import { exec, spawn, toast } from '../assets/kernelsu.js';

const MODID = 'guobao.fbo_plus';
let engine = `/data/adb/modules/${MODID}/fbo.sh`;
// 耗时预估：整分钟表（2 5 8 12 15 20 25 30），超过 8 个每个 +step 分钟
const DEFAULT_ETA = { minutes: [2, 5, 8, 12, 15, 20, 25, 30], cap: 30, timeoutStep: 3 };
const CACHE_KEY = 'fbo_plus_last_v2';

const $ = (id) => document.getElementById(id);

/* ---------------- 基础 ---------------- */

function setChip(text, tone) {
    const chip = $('chip');
    chip.textContent = text;
    chip.className = 'chip' + (tone ? ' ' + tone : '');
}

function makeLineReader(onLine) {
    let buf = '';
    return (chunk) => {
        buf += chunk;
        const lines = buf.split('\n');
        buf = lines.pop() ?? '';
        for (const raw of lines) {
            const t = raw.trim();
            if (!t) continue;
            try { onLine(JSON.parse(t)); } catch { onLine({ ev: 'raw', msg: t }); }
        }
    };
}

function runScript(args, onEvent, onStderr) {
    return new Promise((resolve) => {
        const child = spawn('sh', [engine, ...args]);
        const feed = makeLineReader(onEvent);
        child.stdout.on('data', feed);
        child.stderr.on('data', (d) => onStderr && onStderr(String(d)));
        child.on('exit', (code) => resolve(code ?? 0));
    });
}

async function resolveEngine() {
    try {
        const { errno, stdout } = await exec('ls /data/adb/modules/*/fbo.sh 2>/dev/null | head -n1');
        if (errno === 0 && stdout.trim()) engine = stdout.trim();
    } catch { /* 用默认路径 */ }
}

/* ---------------- 耗时预估 ---------------- */

function etaConf() {
    return state.eta || DEFAULT_ETA;
}

// 超出可量化区间就只说"30 分钟以上"，不再报数字
function isOpenEnded(count) {
    return count > etaConf().minutes.length;
}

function estimateMinutes(count) {
    const e = etaConf();
    if (count <= 0) return 0;
    return count <= e.minutes.length ? e.minutes[count - 1] : e.cap;
}

function estimateLabel(count) {
    const e = etaConf();
    return isOpenEnded(count) ? `${e.cap} 分钟以上` : `${estimateMinutes(count)} 分钟`;
}

function etaHintText(count) {
    const e = etaConf();
    return isOpenEnded(count)
        ? `预计可能需要 ${e.cap} 分钟以上`
        : `预计约 ${estimateMinutes(count)} 分钟`;
}

// 硬超时（秒）：对外封顶，内部仍按数量放宽，避免长任务被提前掐断
function timeoutFor(count) {
    const e = etaConf();
    const minutes = isOpenEnded(count)
        ? e.cap + (count - e.minutes.length) * e.timeoutStep
        : estimateMinutes(count);
    return minutes * 60 + 120;
}

function clock(sec) {
    return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
}

let clockTimer = null;

function startClock(label) {
    clearInterval(clockTimer);
    const t0 = Date.now();
    $('etaHint').textContent = `已用 0:00 · 预计 ${label}`;
    clockTimer = setInterval(() => {
        const s = Math.floor((Date.now() - t0) / 1000);
        $('etaHint').textContent = `已用 ${clock(s)} · 预计 ${label}`;
    }, 1000);
}

function stopClock() {
    clearInterval(clockTimer);
    clockTimer = null;
    updatePicked();
}

/* ---------------- 状态 ---------------- */

const state = {
    probe: null,
    eta: DEFAULT_ETA,
    apps: [],        // [{pkg, mb}]
    picked: new Set(),
    running: false,
    results: [],     // [{pkg, before, after}]
    total: null,
    elapsed: null,
    startedAt: 0,
};

/* ---------------- 探测 ---------------- */

async function probe() {
    let data = null;
    await runScript(['probe'], (ev) => {
        if (ev.ev === 'probe') data = ev.data;
    });
    state.probe = data;
    const p = data;
    const btn = $('runBtn');
    const sub = $('heroSub');

    if (!p) {
        setChip('无法检测', 'bad');
        sub.textContent = '脚本没有返回结果，见下方诊断信息。';
        $('selectBar').hidden = true;
        return;
    }
    if (!p.miui.service) {
        setChip('不支持', 'bad');
        sub.textContent = '系统里没有 miui.fbo.service，这台设备不是澎湃OS 或功能已被移除。';
        return;
    }
    const centerMsg = {
        missing: '手机管家（com.miui.securitycenter）已被卸载。实测这种情况焕新存储会被系统直接中止，结果恒为 0，请先恢复它。',
        suspended: '手机管家处于挂起状态，焕新存储不可用，请取消挂起后再试。',
        disabled: '手机管家被禁用，焕新存储不可用，请启用后再试。',
    }[p.miui.center];
    if (centerMsg) {
        setChip('缺少依赖', 'bad');
        sub.textContent = centerMsg;
        btn.disabled = true;
        $('diag').textContent = JSON.stringify(p, null, 2);
        return;
    }
    if (p.miui.support !== 1) {
        setChip('已禁用', 'bad');
        sub.textContent = '系统报告焕新存储被策略禁用（ActiveFBO_isSupport=0），无法从模块侧打开。';
        btn.disabled = true;
        return;
    }
    setChip('可用', 'ok');
    if (p.miui.eta) state.eta = p.miui.eta;
    sub.textContent = '由澎湃OS 完成分析与整理，单应用约 3 分钟（保守估算）。';
    btn.disabled = false;
    $('selectBar').hidden = false;
    $('diag').textContent = JSON.stringify(p, null, 2);
}

/* ---------------- 应用列表 ---------------- */

async function loadApps() {
    await runScript(['apps'], (ev) => {
        if (ev.ev === 'apps' && Array.isArray(ev.data)) state.apps = ev.data;
    });
    // 默认勾选体积最大的 6 个
    state.apps.slice(0, 6).forEach((a) => state.picked.add(a.pkg));
    renderApps();
    updatePicked();
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
            if (cb.checked) state.picked.add(a.pkg);
            else state.picked.delete(a.pkg);
            updatePicked();
        });
        const name = document.createElement('span');
        name.className = 'pkg';
        name.textContent = a.pkg;
        const size = document.createElement('span');
        size.className = 'mb';
        size.textContent = a.mb ? `${a.mb} MB` : '—';
        label.append(cb, name, size);
        box.append(label);
    }
}

function updatePicked() {
    const n = state.picked.size;
    $('picked').textContent = `已选 ${n} 个`;
    $('runBtn').disabled = n === 0 || state.running;
    $('etaHint').textContent = n ? etaHintText(n) : '至少选择一个应用';
}

/* ---------------- 进度 ---------------- */

const STEPS = [
    { key: 'probe', label: '检测能力' },
    { key: 'service', label: '启动系统服务' },
    { key: 'trigger', label: '触发焕新' },
    { key: 'work', label: '系统分析整理' },
];

function setSteps() {
    const box = $('steps');
    box.hidden = false;
    box.textContent = '';
    for (const s of STEPS) {
        const row = document.createElement('div');
        row.className = 'step';
        row.dataset.key = s.key;
        const dot = document.createElement('span');
        dot.className = 'dot';
        const label = document.createElement('span');
        label.textContent = s.label;
        const detail = document.createElement('span');
        detail.className = 'detail';
        row.append(dot, label, detail);
        box.append(row);
    }
}

function step(key, cls, detail) {
    const row = document.querySelector(`.step[data-key="${key}"]`);
    if (!row) return;
    row.className = 'step ' + (cls || '');
    if (detail !== undefined) row.querySelector('.detail').textContent = detail;
}

/* ---------------- 执行 ---------------- */

async function startRun() {
    if (state.running || state.picked.size === 0) return;
    state.running = true;
    state.results = [];
    state.total = null;
    state.elapsed = null;
    state.startedAt = Date.now();

    const btn = $('runBtn');
    btn.disabled = true;
    btn.textContent = '焕新中…';
    setSteps();
    step('probe', 'active');

    const apps = [...state.picked];
    const timeout = timeoutFor(apps.length);
    startClock(estimateLabel(apps.length));
    const logs = [];

    const onEvent = (ev) => {
        switch (ev.ev) {
            case 'probe':
                step('probe', 'done', ev.data.miui.support === 1 ? '支持' : '不支持');
                break;
            case 'trigger':
                step('service', 'done');
                step('trigger', 'active', `${ev.count} 个`);
                step('trigger', 'done');
                step('work', 'active', `0 / ${ev.count}`);
                break;
            case 'log':
                logs.push(ev.msg);
                if (ev.msg.includes('重启')) step('service', 'active', '重启中');
                if (ev.msg.includes('已启动')) step('service', 'done', '已启动');
                break;
            case 'app':
                state.results.push(ev);
                step('work', 'active', `${state.results.length} / ${apps.length}`);
                renderChart(state.results, null);
                break;
            case 'report':
                state.total = ev.total;
                break;
            case 'error':
                logs.push('错误：' + ev.msg);
                toast(ev.msg);
                break;
            case 'done':
                if (typeof ev.elapsed === 'number') state.elapsed = ev.elapsed;
                if (!ev.ok) step('work', 'failed', ev.reason || '失败');
                break;
        }
    };

    let code = 0;
    let stderr = '';
    try {
        code = await runScript(['run', '--apps', apps.join(','), '--timeout', String(timeout)],
            onEvent, (s) => { stderr += s; });
    } catch (e) {
        logs.push('执行异常：' + e.message);
    }

    state.running = false;
    stopClock();
    btn.textContent = '再次焕新';
    btn.disabled = state.picked.size === 0;

    if (state.results.length) {
        step('work', 'done', `${apps.length} 个`);
        const elapsed = state.elapsed ?? Math.round((Date.now() - state.startedAt) / 1000);
        renderChart(state.results, { elapsed, total: state.total, code });
        save({ results: state.results, total: state.total, elapsed, at: Date.now() });
        showStamp(Date.now());
        toast('焕新完成');
    } else {
        const work = document.querySelector('.step[data-key="work"]');
        if (work && !work.classList.contains('done')) work.classList.add('failed');
    }

    $('diag').textContent = JSON.stringify({
        exitCode: code,
        probe: state.probe,
        logs,
        stderr: stderr.trim(),
        results: state.results,
        total: state.total,
    }, null, 2);
}

/* ---------------- 结果图表 ---------------- */

let maxBefore = 1;

function renderChart(results, meta) {
    const wrap = $('chartWrap');
    const chart = $('chart');
    if (!results || !results.length) return;

    wrap.hidden = false;
    $('resultEmpty').hidden = true;

    // 按整理前碎片数排序，只画前 10 个，其余合并
    const sorted = [...results].sort((a, b) => b.before - a.before);
    const top = sorted.slice(0, 10);
    const rest = sorted.slice(10);
    const rows = [...top];
    if (rest.length) {
        rows.push({
            pkg: `其他 ${rest.length} 个`,
            before: rest.reduce((s, r) => s + r.before, 0),
            after: rest.reduce((s, r) => s + r.after, 0),
        });
    }
    maxBefore = Math.max(...rows.map((r) => r.before), 1);

    chart.textContent = '';
    for (const r of rows) {
        const row = document.createElement('div');
        row.className = 'hrow';

        const name = document.createElement('span');
        name.className = 'hname';
        name.textContent = r.pkg;
        name.title = r.pkg;

        const track = document.createElement('div');
        track.className = 'htrack';
        const before = document.createElement('i');
        before.className = 'hbefore';
        before.style.width = `${(r.before / maxBefore) * 100}%`;
        const after = document.createElement('i');
        after.className = 'hafter';
        after.style.width = `${(r.after / maxBefore) * 100}%`;
        track.append(before, after);

        const num = document.createElement('span');
        num.className = 'hnum';
        num.textContent = r.before === r.after ? `${r.before}` : `${r.before}→${r.after}`;

        row.append(name, track, num);
        chart.append(row);
    }

    if (!meta) return;
    const removed = results.reduce((s, r) => s + Math.max(0, r.before - r.after), 0);
    $('summary').textContent = '';
    $('summary').append(
        metric(String(results.length), '应用数'),
        metric(String(meta.total ?? removed), '减少碎片'),
        metric(`${meta.elapsed}s`, '耗时')
    );
}

function metric(value, label) {
    const d = document.createElement('div');
    d.className = 'metric';
    const b = document.createElement('b');
    b.textContent = value;
    const s = document.createElement('span');
    s.textContent = label;
    d.append(b, s);
    return d;
}

function showStamp(at) {
    const d = new Date(at);
    const pad = (n) => String(n).padStart(2, '0');
    $('stamp').textContent = `${d.getMonth() + 1}/${d.getDate()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/* ---------------- 缓存 ---------------- */

function save(data) {
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(data)); } catch { /* 忽略 */ }
}

function load() {
    try {
        const d = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
        return d && d.at ? d : null;
    } catch {
        return null;
    }
}

/* ---------------- 启动 ---------------- */

(async function init() {
    await resolveEngine();
    await probe();
    if (state.probe && state.probe.miui && state.probe.miui.support === 1) {
        $('picked').textContent = '正在统计应用体积…';
        await loadApps();
    }

    const cached = load();
    if (cached && cached.results) {
        renderChart(cached.results, cached);
        showStamp(cached.at);
    }

    $('toggleList').addEventListener('click', () => {
        const box = $('applist');
        box.hidden = !box.hidden;
        $('toggleList').textContent = box.hidden ? '选择应用' : '收起';
    });

    $('runBtn').addEventListener('click', startRun);

    if (!state.probe) $('diag').textContent = '探测失败：引擎没有输出。';
})();
