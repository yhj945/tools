// ==UserScript==
// @name         Codex配额用量分析工具
// @namespace    http://tampermonkey.net/
// @version      1.0
// @description  对 BlueSkyXN 原始 codex-quota-compass.js 的页面封装版，直接整理为表格数据后渲染，保留原始数据源获取与核心计算逻辑
// @author       yhj945（页面封装） / BlueSkyXN（原始逻辑：https://gist.github.com/BlueSkyXN/528e810b98affcecca170e6b9d53d7da）
// @match        https://chatgpt.com/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function() {
    'use strict';

    const CACHE_KEY = 'codex-quota-compass:last-analysis';
    const EMPTY_STATE_HTML = '<div style="text-align:center; padding:50px; color:#999; font-size: 15px;">请点击左下角 📊 悬浮球，选择“运行全量分析”</div>';

    let lastAnalysisData = null;

    function formatLastRunTime(timestamp) {
        if (!timestamp) return '';
        const date = new Date(timestamp);
        if (Number.isNaN(date.getTime())) return '';
        return date.toLocaleString();
    }

    function escapeHtml(text) {
        return String(text ?? '')
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('"', '&quot;')
            .replaceAll("'", '&#39;');
    }

    function updateLastRunDisplay(timestamp) {
        const label = document.getElementById('q-last-run');
        if (!label) return;
        const text = formatLastRunTime(timestamp);
        label.textContent = text ? `上次分析：${text}` : '尚无缓存';
    }

    function loadCachedAnalysis() {
        try {
            const raw = localStorage.getItem(CACHE_KEY);
            if (!raw) return null;
            const parsed = JSON.parse(raw);
            if (!parsed || typeof parsed.html !== 'string') return null;
            return parsed;
        } catch {
            return null;
        }
    }

    function saveCachedAnalysis(html, timestamp, exportData) {
        try {
            localStorage.setItem(CACHE_KEY, JSON.stringify({ html, timestamp, exportData }));
            lastAnalysisData = exportData ?? null;
            updateLastRunDisplay(timestamp);
        } catch (error) {
            window.console.warn('缓存分析结果失败', error);
        }
    }

    function clearCachedAnalysis() {
        try {
            localStorage.removeItem(CACHE_KEY);
        } catch (error) {
            window.console.warn('清空缓存失败', error);
        }
        lastAnalysisData = null;
        const content = document.getElementById('q-content');
        if (content) content.innerHTML = EMPTY_STATE_HTML;
        updateLastRunDisplay(null);
    }

    function formatFileTimestamp(timestamp) {
        const date = new Date(timestamp || Date.now());
        if (Number.isNaN(date.getTime())) return 'unknown-time';
        const pad = (value) => String(value).padStart(2, '0');
        return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
    }

    function exportAnalysisJson() {
        const cached = loadCachedAnalysis();
        const exportData = lastAnalysisData ?? cached?.exportData;
        const timestamp = cached?.timestamp ?? Date.now();
        if (!exportData) {
            window.alert('暂无可导出的分析数据，请先运行一次全量分析。');
            return;
        }

        const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = `codex-quota-compass-${formatFileTimestamp(timestamp)}.json`;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
    }

    function stringifyCellValue(value) {
        if (typeof value === 'object' && value !== null) {
            return JSON.stringify(value);
        }
        return value ?? '';
    }

    function renderTextBlock(text) {
        return `<div class="q-text" style="white-space:pre-wrap;">${escapeHtml(text)}</div>`;
    }

    function renderTable(rows, options = {}) {
        const { mode = 'table', wideFirstColumn = false } = options;
        const arr = Array.isArray(rows) ? rows : [];
        if (arr.length === 0) {
            return '<div class="q-text">(暂无数据 / 空数组)</div>';
        }

        if (mode === 'kv') {
            const pairs = Object.entries(arr[0]).filter(([key]) => !key.startsWith('_'));
            let html = `<div class="q-table-wrapper"><table class="q-table"><thead><tr><th${wideFirstColumn ? ' class="q-kv-first"' : ''}>项目</th><th>值</th></tr></thead><tbody>`;
            pairs.forEach(([key, value]) => {
                html += `<tr><td>${escapeHtml(key)}</td><td>${escapeHtml(stringifyCellValue(value))}</td></tr>`;
            });
            html += '</tbody></table></div>';
            return html;
        }

        const keys = Object.keys(arr[0]).filter((key) => !key.startsWith('_'));
        let html = '<div class="q-table-wrapper"><table class="q-table"><thead><tr>';
        keys.forEach((key, index) => {
            html += `<th${wideFirstColumn && index === 0 ? ' class="q-kv-first"' : ''}>${escapeHtml(key)}</th>`;
        });
        html += '</tr></thead><tbody>';
        arr.forEach((row) => {
            html += '<tr>';
            keys.forEach((key) => {
                html += `<td>${escapeHtml(stringifyCellValue(row[key]))}</td>`;
            });
            html += '</tr>';
        });
        html += '</tbody></table></div>';
        return html;
    }

    function renderAnalysisData(content, analysisData) {
        content.innerHTML = '';
        analysisData.sections.forEach((section) => {
            content.innerHTML += `<div class="q-title">${escapeHtml(section.title)}</div>`;
            (section.urls ?? []).forEach((url) => {
                content.innerHTML += `<div class="q-url">${escapeHtml(url)}</div>`;
            });
            (section.texts ?? []).forEach((text) => {
                content.innerHTML += renderTextBlock(text);
            });
            if (section.rows) {
                content.innerHTML += renderTable(section.rows, {
                    mode: section.mode,
                    wideFirstColumn: section.wideFirstColumn,
                });
            }
        });
    }

    const style = document.createElement('style');
    style.innerHTML = `
        #q-ball { position: fixed; bottom: 30px; right: 30px; z-index: 100000; width: 54px; height: 54px; border-radius: 50%; background: #10a37f; color: white; border: 2px solid white; cursor: pointer; box-shadow: 0 4px 15px rgba(0,0,0,0.3); font-size: 26px; display: flex; align-items: center; justify-content: center; transition: 0.3s; user-select: none; }
        #q-ball:hover { transform: scale(1.1); background: #1a7f64; }
        #q-menu { position: fixed; bottom: 95px; right: 30px; z-index: 100000; background: #fff; border: 1px solid #ddd; border-radius: 12px; box-shadow: 0 8px 30px rgba(0,0,0,0.2); display: none; flex-direction: column; min-width: 180px; font-family: sans-serif; overflow: hidden; }
        .q-item { padding: 12px 20px; font-size: 14px; cursor: pointer; border-bottom: 1px solid #eee; color: #333; }
        .q-item:hover { background: #f7f7f8; }

        #q-win { position: fixed; top: 3%; right: 3%; left: 3%; bottom: 3%; z-index: 99999; background: #fff; border-radius: 10px; box-shadow: 0 20px 60px rgba(0,0,0,0.4); display: none; flex-direction: column; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; overflow: hidden; border: 1px solid #ccc; }
        .q-win-header { padding: 12px 20px; background: #10a37f; color: white; display: flex; justify-content: space-between; align-items: center; font-weight: bold; font-size: 16px; }
        .q-win-body { flex: 1; overflow-y: auto; padding: 20px; background: #fdfdfd; font-size: 13px; color: #333; }

        .q-title { font-size: 16px; font-weight: bold; color: #10a37f; margin: 30px 0 10px; border-bottom: 2px solid #e5e5e5; padding-bottom: 6px; }
        .q-title:first-child { margin-top: 0; }
        .q-url { font-family: monospace; color: #005cc5; background: #f1f8ff; padding: 6px 10px; border-radius: 4px; margin-bottom: 10px; font-size: 12px; word-break: break-all; border-left: 3px solid #0366d6; }
        .q-text { margin-bottom: 10px; color: #666; font-size: 13px; line-height: 1.5; background: #f6f8fa; padding: 8px 12px; border-radius: 6px; }

        .q-table-wrapper { width: 100%; overflow-x: auto; margin-bottom: 20px; border: 1px solid #dfe2e5; border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
        .q-table { width: 100%; border-collapse: collapse; background: white; white-space: nowrap; }
        .q-table th { background: #f6f8fa; padding: 8px 12px; text-align: left; border: 1px solid #dfe2e5; font-size: 12px; color: #24292e; font-weight: 600; position: sticky; top: 0; z-index: 10; }
        .q-table td { padding: 8px 12px; border: 1px solid #dfe2e5; font-size: 12px; color: #24292e; }
        .q-table tr:nth-child(even) { background-color: #fafbfc; }
        .q-table tr:hover { background-color: #f1f8ff; }
        .q-kv-first { width: 300px; max-width: 300px; }

        .q-table-wrapper::-webkit-scrollbar { height: 10px; }
        .q-table-wrapper::-webkit-scrollbar-track { background: #f1f1f1; border-radius: 4px; }
        .q-table-wrapper::-webkit-scrollbar-thumb { background: #c1c1c1; border-radius: 4px; }
        .q-table-wrapper::-webkit-scrollbar-thumb:hover { background: #a8a8a8; }
    `;
    document.head.appendChild(style);

    const ball = document.createElement('div');
    ball.id = 'q-ball';
    ball.innerHTML = '📊';
    document.body.appendChild(ball);

    const menu = document.createElement('div');
    menu.id = 'q-menu';
    menu.innerHTML = `
        <div class="q-item" id="q-run">🚀 运行全量分析</div>
        <div class="q-item" id="q-toggle">👁️ 显示/隐藏窗口</div>
        <div class="q-item" id="q-export">💾 导出数据 JSON</div>
        <div class="q-item" id="q-clear-cache">🗑️ 清空缓存</div>
        <div class="q-item" id="q-close-menu">❌ 关闭菜单</div>
    `;
    document.body.appendChild(menu);

    const win = document.createElement('div');
    win.id = 'q-win';
    win.innerHTML = `
        <div class="q-win-header">
            <div style="display:flex; align-items:baseline; gap:12px; min-width:0;">
                <span>Codex配额用量分析数据看板</span>
                <span id="q-last-run" style="font-weight:normal;font-size:12px;opacity:0.9;white-space:nowrap;"></span>
            </div>
            <span style="cursor:pointer;font-size:24px;line-height:1;" id="q-close-win">&times;</span>
        </div>
        <div class="q-win-body" id="q-content">
            ${EMPTY_STATE_HTML}
        </div>
    `;
    document.body.appendChild(win);

    const cachedAnalysis = loadCachedAnalysis();
    if (cachedAnalysis?.html) {
        document.getElementById('q-content').innerHTML = cachedAnalysis.html;
    }
    lastAnalysisData = cachedAnalysis?.exportData ?? null;
    updateLastRunDisplay(cachedAnalysis?.timestamp);

    ball.onclick = (event) => {
        menu.style.display = menu.style.display === 'flex' ? 'none' : 'flex';
        event.stopPropagation();
    };
    document.addEventListener('click', () => {
        menu.style.display = 'none';
    });
    document.getElementById('q-close-menu').onclick = () => {
        menu.style.display = 'none';
    };
    document.getElementById('q-close-win').onclick = () => {
        win.style.display = 'none';
    };
    document.getElementById('q-toggle').onclick = () => {
        win.style.display = win.style.display === 'flex' ? 'none' : 'flex';
    };
    document.getElementById('q-export').onclick = () => {
        menu.style.display = 'none';
        exportAnalysisJson();
    };
    document.getElementById('q-clear-cache').onclick = () => {
        menu.style.display = 'none';
        clearCachedAnalysis();
    };

    document.getElementById('q-run').onclick = async () => {
        menu.style.display = 'none';
        const content = document.getElementById('q-content');
        content.innerHTML = '<div style="text-align:center; padding:40px; font-size:16px;">🚀 正在拉取所有 API 并计算数据，请耐心等待...</div>';
        win.style.display = 'flex';

        try {
            const exportData = await buildAnalysisData();
            renderAnalysisData(content, exportData);
            saveCachedAnalysis(content.innerHTML, Date.now(), exportData);
        } catch (error) {
            content.innerHTML += `<div style="color:red; font-weight:bold; margin-top:20px; padding:15px; background:#ffeeee; border-radius:6px; white-space:pre-wrap;">❌ 运行中断:\n${escapeHtml(error?.message ?? '未知错误')}</div>`;
            window.console.error(error);
        }
    };

    async function buildAnalysisData() {
        const CONFIG = {
            DATE_BUCKET_MODE: 'utc', // 推荐：'utc'；可改为 'local' 对比
            USD_PER_CREDIT: 40 / 1000, // 1000 credits = 40 USD
            ROLLING_DAYS: 30,
            // 不建议使用。只有自动取不到 accessToken 时，才在自己电脑临时填写 Bearer 后面的内容。
            // 发布脚本、截图、复制输出前，必须保持为空。
            MANUAL_ACCESS_TOKEN: '',
            USAGE_PATH: '/backend-api/wham/usage',
            DAILY_USAGE_PATH: '/backend-api/wham/analytics/daily-workspace-usage-counts',
        };

        if (location.hostname !== 'chatgpt.com') {
            throw new Error('请在 chatgpt.com 页面运行，例如 Codex Usage / Analytics 页面。');
        }

        const DAY_MS = 24 * 60 * 60 * 1000;
        const n = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0);
        const round = (value, digits = 2) => Number(Number(value).toFixed(digits));
        const pad2 = (value) => String(value).padStart(2, '0');
        const last = (arr) => (arr.length ? arr[arr.length - 1] : undefined);

        const fmtLocal = (ms) => new Date(ms).toLocaleString();
        const fmtUTC = (ms) => new Date(ms).toISOString().replace('T', ' ').replace('.000Z', ' UTC');

        const ymdUTC = (value) => {
            const date = new Date(value);
            return [date.getUTCFullYear(), pad2(date.getUTCMonth() + 1), pad2(date.getUTCDate())].join('-');
        };

        const ymdLocal = (value) => {
            const date = new Date(value);
            date.setMinutes(date.getMinutes() - date.getTimezoneOffset());
            return date.toISOString().slice(0, 10);
        };

        const ymdForApi = (ms) => (CONFIG.DATE_BUCKET_MODE === 'utc' ? ymdUTC(ms) : ymdLocal(ms));

        const addDaysLocalMs = (ms, days) => {
            const date = new Date(ms);
            date.setDate(date.getDate() + days);
            return date.getTime();
        };

        const addDaysForApi = (ms, days) => (CONFIG.DATE_BUCKET_MODE === 'utc' ? ms + days * DAY_MS : addDaysLocalMs(ms, days));

        const firstDayOfMonthUTC = (ms) => {
            const date = new Date(ms);
            return `${date.getUTCFullYear()}-${pad2(date.getUTCMonth() + 1)}-01`;
        };

        const firstDayOfMonthLocal = (ms) => {
            const date = new Date(ms);
            return ymdLocal(new Date(date.getFullYear(), date.getMonth(), 1).getTime());
        };

        const firstDayOfMonthForApi = (ms) => (CONFIG.DATE_BUCKET_MODE === 'utc' ? firstDayOfMonthUTC(ms) : firstDayOfMonthLocal(ms));

        const utcOffsetLabel = (ms) => {
            const offsetMinutes = -new Date(ms).getTimezoneOffset();
            const sign = offsetMinutes >= 0 ? '+' : '-';
            const abs = Math.abs(offsetMinutes);
            return `UTC${sign}${pad2(Math.floor(abs / 60))}:${pad2(abs % 60)}`;
        };

        const tokenTotal = (obj = {}) => n(obj.text_total_tokens) || n(obj.cached_text_input_tokens) + n(obj.uncached_text_input_tokens) + n(obj.text_output_tokens);
        const stripBearer = (value) => String(value || '').replace(/^Bearer\s+/i, '').trim();
        const looksLikeJwt = (value) => typeof value === 'string' && value.length > 100 && value.split('.').length >= 3;

        function findAccessToken(obj, depth = 0) {
            if (!obj || typeof obj !== 'object' || depth > 8) return '';
            for (const [key, value] of Object.entries(obj)) {
                if (typeof value === 'string' && /access/i.test(key) && looksLikeJwt(value)) return value;
                if (value && typeof value === 'object') {
                    const found = findAccessToken(value, depth + 1);
                    if (found) return found;
                }
            }
            return '';
        }

        async function getAccessToken() {
            const manual = stripBearer(CONFIG.MANUAL_ACCESS_TOKEN);
            if (manual) return manual;
            try {
                const res = await fetch('/api/auth/session', {
                    credentials: 'include',
                    headers: { accept: 'application/json' },
                });
                if (!res.ok) return '';
                return findAccessToken(await res.json());
            } catch {
                return '';
            }
        }

        const accessToken = await getAccessToken();
        const headers = { accept: 'application/json' };
        if (accessToken) {
            headers.authorization = `Bearer ${accessToken}`;
        }

        async function apiGet(path) {
            const res = await fetch(path, {
                method: 'GET',
                credentials: 'include',
                headers,
            });

            if (!res.ok) {
                const text = await res.text().catch(() => '');
                if (res.status === 401) {
                    throw new Error([
                        `HTTP 401 Unauthorized: ${path}`,
                        '',
                        '没有拿到有效 Authorization。',
                        '处理方式：',
                        '1. 先确认你已经登录 chatgpt.com，并在同一个页面运行脚本。',
                        '2. 刷新 Codex Usage / Analytics 页面后重试。',
                        '3. 仍失败时，可在 Network 面板找到成功的 /backend-api/wham/usage 请求，',
                        '   复制 Authorization: Bearer 后面的 token，只在自己电脑临时填到 CONFIG.MANUAL_ACCESS_TOKEN。',
                        '',
                        '不要把 token、Cookie、填过 token 的脚本或截图发给任何人。',
                    ].join('\n'));
                }

                throw new Error(`HTTP ${res.status} ${res.statusText}: ${path}\n${text.slice(0, 800)}`);
            }

            return res.json();
        }

        function parseWindow(label, windowData) {
            const usedPercent = n(windowData?.used_percent);
            const windowSeconds = n(windowData?.limit_window_seconds);
            const resetAfterSeconds = n(windowData?.reset_after_seconds);
            const resetAtSeconds = n(windowData?.reset_at);
            const resetAtMs = resetAtSeconds * 1000;
            const windowStartMs = resetAtMs - windowSeconds * 1000;
            const serverNowMs = resetAtMs - resetAfterSeconds * 1000;
            return {
                名称: label,
                已用百分比: usedPercent,
                已用比例小数: round(usedPercent / 100, 4),
                窗口秒数: windowSeconds,
                窗口天数: round(windowSeconds / 86400, 4),
                本轮开始_UTC: fmtUTC(windowStartMs),
                本轮开始_本地: fmtLocal(windowStartMs),
                下次重置_UTC: fmtUTC(resetAtMs),
                下次重置_本地: fmtLocal(resetAtMs),
                后端当前_UTC: fmtUTC(serverNowMs),
                后端当前_本地: fmtLocal(serverNowMs),
                距离重置小时: round(resetAfterSeconds / 3600, 2),
                _windowStartMs: windowStartMs,
                _resetAtMs: resetAtMs,
                _serverNowMs: serverNowMs,
            };
        }

        function collectWindows(usage) {
            const windows = [];
            if (usage?.rate_limit?.primary_window) {
                windows.push(parseWindow('主限制 - 5小时窗口', usage.rate_limit.primary_window));
            }
            if (usage?.rate_limit?.secondary_window) {
                windows.push(parseWindow('主限制 - 7天窗口', usage.rate_limit.secondary_window));
            }
            for (const item of usage?.additional_rate_limits ?? []) {
                const name = item.limit_name || item.metered_feature || '额外限制';
                if (item?.rate_limit?.primary_window) {
                    windows.push(parseWindow(`${name} - 5小时窗口`, item.rate_limit.primary_window));
                }
                if (item?.rate_limit?.secondary_window) {
                    windows.push(parseWindow(`${name} - 7天窗口`, item.rate_limit.secondary_window));
                }
            }
            return windows;
        }

        function parseDailyRows(json) {
            return (json.data ?? [])
                .slice()
                .sort((left, right) => String(left.date).localeCompare(String(right.date)))
                .map((day) => {
                    const totals = day.totals ?? {};
                    const credits = n(totals.credits);
                    return {
                        日期桶: day.date,
                        Credits: round(credits, 6),
                        折算USD: round(credits * CONFIG.USD_PER_CREDIT, 2),
                        用户数: n(totals.users),
                        线程数: n(totals.threads),
                        轮数: n(totals.turns),
                        Token总量: tokenTotal(totals),
                        缓存输入Token: n(totals.cached_text_input_tokens),
                        非缓存输入Token: n(totals.uncached_text_input_tokens),
                        输出Token: n(totals.text_output_tokens),
                        客户端数量: Array.isArray(day.clients) ? day.clients.length : 0,
                        客户端Credits: (day.clients ?? []).map((client) => `${client.client_id ?? 'UNKNOWN'}:${round(n(client.credits), 2)}`).join(' | '),
                    };
                });
        }

        function summarizeClients(json) {
            const map = new Map();
            for (const day of json.data ?? []) {
                for (const client of day.clients ?? []) {
                    const id = client.client_id ?? 'UNKNOWN';
                    const row = map.get(id) ?? {
                        客户端: id,
                        Credits: 0,
                        折算USD: 0,
                        线程数: 0,
                        轮数: 0,
                        Token总量: 0,
                        缓存输入Token: 0,
                        非缓存输入Token: 0,
                        输出Token: 0,
                    };
                    const credits = n(client.credits);
                    row.Credits += credits;
                    row.折算USD += credits * CONFIG.USD_PER_CREDIT;
                    row.线程数 += n(client.threads);
                    row.轮数 += n(client.turns);
                    row.Token总量 += tokenTotal(client);
                    row.缓存输入Token += n(client.cached_text_input_tokens);
                    row.非缓存输入Token += n(client.uncached_text_input_tokens);
                    row.输出Token += n(client.text_output_tokens);
                    map.set(id, row);
                }
            }

            return [...map.values()]
                .map((row) => ({
                    ...row,
                    Credits: round(row.Credits, 6),
                    折算USD: round(row.折算USD, 2),
                }))
                .sort((left, right) => right.Credits - left.Credits);
        }

        async function fetchDailyUsage(startDate, endExclusiveDate) {
            const qs = new URLSearchParams({
                start_date: startDate,
                end_date: endExclusiveDate,
                group_by: 'day',
            });
            const url = `${CONFIG.DAILY_USAGE_PATH}?${qs}`;
            const json = await apiGet(url);
            return {
                url: location.origin + url,
                rows: parseDailyRows(json),
                clients: summarizeClients(json),
            };
        }

        function summarizeRows(rangeName, rows, startDate, endExclusiveDate) {
            const credits = rows.reduce((sum, row) => sum + n(row.Credits), 0);
            return {
                范围: rangeName,
                日期桶口径: CONFIG.DATE_BUCKET_MODE === 'utc' ? 'UTC日期桶' : '本地日期桶',
                API_start_date: startDate,
                API_end_date_排他: endExclusiveDate,
                返回日期桶数: rows.length,
                首个返回日期桶: rows[0]?.日期桶 ?? '',
                最后返回日期桶: last(rows)?.日期桶 ?? '',
                累计Credits: round(credits, 6),
                累计折算USD: round(credits * CONFIG.USD_PER_CREDIT, 2),
                累计Token: rows.reduce((sum, row) => sum + n(row.Token总量), 0),
                累计线程数: rows.reduce((sum, row) => sum + n(row.线程数), 0),
                累计轮数: rows.reduce((sum, row) => sum + n(row.轮数), 0),
            };
        }

        function publicWindowRow(windowRow) {
            const { _windowStartMs, _resetAtMs, _serverNowMs, ...visible } = windowRow;
            return visible;
        }

        function buildTimezoneDiagnosticsRows({ apiNowMs, windowStartMs, resetAtMs, sinceResetStartDate, monthStartDate, rollingStartDate, endExclusiveDate }) {
            const browserTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || '未知';
            return [
                { 项目: '浏览器本地时区', 值: browserTimeZone },
                { 项目: '浏览器UTC偏移', 值: utcOffsetLabel(apiNowMs) },
                { 项目: '当前脚本日期桶模式', 值: CONFIG.DATE_BUCKET_MODE === 'utc' ? 'UTC日期桶' : '本地日期桶' },
                { 项目: '浏览器当前时间_本地', 值: fmtLocal(Date.now()) },
                { 项目: '浏览器当前时间_UTC', 值: fmtUTC(Date.now()) },
                { 项目: '后端当前时间_本地', 值: fmtLocal(apiNowMs) },
                { 项目: '后端当前时间_UTC', 值: fmtUTC(apiNowMs) },
                { 项目: '浏览器时间与后端时间差_秒', 值: round((Date.now() - apiNowMs) / 1000, 2) },
                { 项目: '7天窗口开始_本地', 值: fmtLocal(windowStartMs) },
                { 项目: '7天窗口开始_UTC', 值: fmtUTC(windowStartMs) },
                { 项目: '下次重置时间_本地', 值: fmtLocal(resetAtMs) },
                { 项目: '下次重置时间_UTC', 值: fmtUTC(resetAtMs) },
                { 项目: '7天窗口开始日期_本地口径', 值: ymdLocal(windowStartMs) },
                { 项目: '7天窗口开始日期_UTC口径', 值: ymdUTC(windowStartMs) },
                { 项目: '后端当前日期_本地口径', 值: ymdLocal(apiNowMs) },
                { 项目: '后端当前日期_UTC口径', 值: ymdUTC(apiNowMs) },
                { 项目: '本月月初_本地口径', 值: firstDayOfMonthLocal(apiNowMs) },
                { 项目: '本月月初_UTC口径', 值: firstDayOfMonthUTC(apiNowMs) },
                { 项目: 'API_start_date_上次重置至今', 值: sinceResetStartDate },
                { 项目: 'API_start_date_本月初至今', 值: monthStartDate },
                { 项目: `API_start_date_近${CONFIG.ROLLING_DAYS}天`, 值: rollingStartDate },
                { 项目: 'API_end_date_排他', 值: endExclusiveDate },
            ];
        }

        function buildWeeklyEstimate({ mainSecondary, sinceResetRows, sinceResetSummary, sinceResetStartDate }) {
            const usedPercent = n(mainSecondary.已用百分比);
            const usedRatio = usedPercent / 100;
            const includedCredits = n(sinceResetSummary.累计Credits);
            const resetDayRow = sinceResetRows.find((row) => row.日期桶 === sinceResetStartDate);
            const resetDayCredits = n(resetDayRow?.Credits);
            const excludedCredits = Math.max(0, includedCredits - resetDayCredits);

            if (usedRatio <= 0) {
                return {
                    依据: '主限制 - 7天窗口 secondary_window',
                    已用百分比: usedPercent,
                    说明: '已用比例为 0，无法反推总额度。',
                };
            }

            const totalWithResetDay = includedCredits / usedRatio;
            const totalWithoutResetDay = excludedCredits / usedRatio;
            const remainingWithResetDay = Math.max(0, totalWithResetDay - includedCredits);
            const remainingWithoutResetDay = Math.max(0, totalWithoutResetDay - excludedCredits);

            return {
                依据: '主限制 - 7天窗口 secondary_window',
                已用百分比: usedPercent,
                已用比例小数: round(usedRatio, 4),
                剩余比例小数: round(1 - usedRatio, 4),
                说明: 'used_percent 表示已经用掉的比例；例如 45 = 已用 45%，不是剩余 45%。',
                日期桶口径: CONFIG.DATE_BUCKET_MODE === 'utc' ? 'UTC日期桶' : '本地日期桶',
                包含重置日_已用Credits: round(includedCredits, 6),
                包含重置日_已用折算USD: round(includedCredits * CONFIG.USD_PER_CREDIT, 2),
                重置日整天Credits: round(resetDayCredits, 6),
                重置日整天折算USD: round(resetDayCredits * CONFIG.USD_PER_CREDIT, 2),
                排除重置日_已用Credits: round(excludedCredits, 6),
                排除重置日_已用折算USD: round(excludedCredits * CONFIG.USD_PER_CREDIT, 2),
                反推周总Credits_包含重置日: round(totalWithResetDay, 2),
                反推周总USD_包含重置日: round(totalWithResetDay * CONFIG.USD_PER_CREDIT, 2),
                反推周总Credits_排除重置日: round(totalWithoutResetDay, 2),
                反推周总USD_排除重置日: round(totalWithoutResetDay * CONFIG.USD_PER_CREDIT, 2),
                剩余Credits_包含重置日口径: round(remainingWithResetDay, 2),
                剩余USD_包含重置日口径: round(remainingWithResetDay * CONFIG.USD_PER_CREDIT, 2),
                剩余Credits_排除重置日口径: round(remainingWithoutResetDay, 2),
                剩余USD_排除重置日口径: round(remainingWithoutResetDay * CONFIG.USD_PER_CREDIT, 2),
                误差说明: 'daily analytics 只能按天聚合，不能切到具体小时分钟；实际值通常介于“排除重置日”和“包含重置日”之间。used_percent 也是整数，存在四舍五入或截断误差。',
            };
        }

        const usage = await apiGet(CONFIG.USAGE_PATH);
        const windows = collectWindows(usage);
        if (!usage?.rate_limit?.secondary_window) {
            throw new Error('没有找到 usage.rate_limit.secondary_window，无法反推主 7 天窗口。');
        }

        const mainSecondary = parseWindow('主限制 - 7天窗口', usage.rate_limit.secondary_window);
        const apiNowMs = mainSecondary._serverNowMs || Date.now();
        const apiTodayDate = ymdForApi(apiNowMs);
        const endExclusiveDate = ymdForApi(addDaysForApi(apiNowMs, 1));
        const sinceResetStartDate = ymdForApi(mainSecondary._windowStartMs);
        const monthStartDate = firstDayOfMonthForApi(apiNowMs);
        const rollingStartDate = ymdForApi(addDaysForApi(apiNowMs, -(CONFIG.ROLLING_DAYS - 1)));

        const sinceReset = await fetchDailyUsage(sinceResetStartDate, endExclusiveDate);
        const sinceResetSummary = summarizeRows(`上次重置至今近似 ${sinceResetStartDate} ~ ${apiTodayDate}`, sinceReset.rows, sinceResetStartDate, endExclusiveDate);
        const weeklyEstimate = buildWeeklyEstimate({
            mainSecondary,
            sinceResetRows: sinceReset.rows,
            sinceResetSummary,
            sinceResetStartDate,
        });
        const monthToDate = await fetchDailyUsage(monthStartDate, endExclusiveDate);
        const monthToDateSummary = summarizeRows(`本月初至今 ${monthStartDate} ~ ${apiTodayDate}`, monthToDate.rows, monthStartDate, endExclusiveDate);
        const rolling = await fetchDailyUsage(rollingStartDate, endExclusiveDate);
        const rollingSummary = summarizeRows(`近${CONFIG.ROLLING_DAYS}天 ${rollingStartDate} ~ ${apiTodayDate}`, rolling.rows, rollingStartDate, endExclusiveDate);

        return {
            exportedAt: new Date().toISOString(),
            source: 'Codex配额用量分析工具',
            sections: [
                {
                    title: '配置',
                    mode: 'table',
                    rows: [{
                        日期桶模式: CONFIG.DATE_BUCKET_MODE,
                        USD_PER_CREDIT: CONFIG.USD_PER_CREDIT,
                        ROLLING_DAYS: CONFIG.ROLLING_DAYS,
                    }],
                },
                {
                    title: '0）时区诊断：刷新周期与用量日期桶',
                    mode: 'table',
                    wideFirstColumn: true,
                    rows: buildTimezoneDiagnosticsRows({
                        apiNowMs,
                        windowStartMs: mainSecondary._windowStartMs,
                        resetAtMs: mainSecondary._resetAtMs,
                        sinceResetStartDate,
                        monthStartDate,
                        rollingStartDate,
                        endExclusiveDate,
                    }),
                },
                {
                    title: '1）限制窗口概览：刷新周期 UTC / 本地对照',
                    mode: 'table',
                    rows: windows.map(publicWindowRow),
                },
                {
                    title: '2）主 7 天窗口：上次重置至今，按 daily analytics 近似',
                    urls: [sinceReset.url],
                    mode: 'table',
                    rows: [sinceResetSummary],
                },
                {
                    title: '3）用 used_percent 反推周额度',
                    mode: 'kv',
                    wideFirstColumn: true,
                    rows: [weeklyEstimate],
                },
                {
                    title: '4）上次重置至今每日明细',
                    mode: 'table',
                    rows: sinceReset.rows,
                },
                {
                    title: '4.1）上次重置至今客户端汇总',
                    mode: 'table',
                    rows: sinceReset.clients,
                },
                {
                    title: '5）本月初至今汇总',
                    urls: [monthToDate.url],
                    mode: 'table',
                    rows: [monthToDateSummary],
                },
                {
                    title: '6）本月初至今日明细',
                    mode: 'table',
                    rows: monthToDate.rows,
                },
                {
                    title: '6.1）本月初至今客户端汇总',
                    mode: 'table',
                    rows: monthToDate.clients,
                },
                {
                    title: `7）近${CONFIG.ROLLING_DAYS}天汇总`,
                    urls: [rolling.url],
                    mode: 'table',
                    rows: [rollingSummary],
                },
                {
                    title: `8）近${CONFIG.ROLLING_DAYS}天每日明细`,
                    mode: 'table',
                    rows: rolling.rows,
                },
                {
                    title: `8.1）近${CONFIG.ROLLING_DAYS}天客户端汇总`,
                    mode: 'table',
                    rows: rolling.clients,
                },
                {
                    title: '说明',
                    texts: ['end_date 是排他边界；如果今天没有返回，通常是 daily analytics 尚未刷新或当天暂无统计。'],
                },
            ],
        };
    }
})();