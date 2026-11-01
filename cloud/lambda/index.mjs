// Torpet El in the cloud: fetches the plugs from Tuya every five minutes, saves readings to DynamoDB
// and sends alarms through ntfy. Same alarm rules as the Mac app (Sources/TorpetEl/Alarm.swift), but
// evaluated one reading at a time, and it keeps watching while the Mac sleeps.
//
// The same function also answers the Mac app over its Function URL (see cloud/README.md).

import crypto from 'node:crypto';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  BatchGetCommand, BatchWriteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand, UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { GetParametersByPathCommand, SSMClient } from '@aws-sdk/client-ssm';

const TABLE = process.env.TABLE;
const PARAM_PATH = process.env.PARAM_PATH ?? '/torpet-el';
const KEEP_DAYS = Number(process.env.KEEP_DAYS ?? 90);
/** A longer gap between readings restarts a period, as in the app: we don't know what happened meanwhile. */
const MAX_GAP = 20 * 60;
/** Alarm when Tuya has failed this long (expired trial, wrong keys, Tuya down). */
const TUYA_FAIL_ALARM = 30 * 60;

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
const ssm = new SSMClient({});

const HOSTS = {
  centralEurope: 'https://openapi.tuyaeu.com',
  westernEurope: 'https://openapi-weaz.tuyaeu.com',
  westernAmerica: 'https://openapi.tuyaus.com',
  easternAmerica: 'https://openapi-ueaz.tuyaus.com',
  china: 'https://openapi.tuyacn.com',
  india: 'https://openapi.tuyain.com',
};

let lang = 'sv';
const L = (sv, en) => (lang === 'en' ? en : sv);

// MARK: - Settings from Parameter Store

let cfgCache;

async function config() {
  if (cfgCache && Date.now() - cfgCache.at < 10 * 60_000) return cfgCache.cfg;
  const p = {};
  let NextToken;
  do {
    const r = await ssm.send(new GetParametersByPathCommand({ Path: PARAM_PATH, WithDecryption: true, NextToken }));
    for (const x of r.Parameters ?? []) p[x.Name.slice(PARAM_PATH.length + 1)] = x.Value;
    NextToken = r.NextToken;
  } while (NextToken);
  const region = p['tuya-region'] ?? 'centralEurope';
  const cfg = {
    accessId: p['tuya-access-id']?.trim(),
    secret: p['tuya-access-secret']?.trim(),
    host: HOSTS[region] ?? region,
    ntfyServer: (p['ntfy-server'] ?? 'https://ntfy.sh').replace(/\/+$/, ''),
    ntfyTopic: p['ntfy-topic'],
    ntfyToken: p['ntfy-token'],
    apiKey: p['api-key'],
    lang: p.language === 'en' ? 'en' : 'sv',
    trialExpires: /^\d{4}-\d{2}-\d{2}$/.test(p['tuya-trial-expires']?.trim() ?? '') ? p['tuya-trial-expires'].trim() : null,
  };
  cfgCache = { at: Date.now(), cfg };
  return cfg;
}

// MARK: - Tuya

class TuyaError extends Error {
  constructor(code, msg) {
    super(tuyaMessage(code, msg));
    this.code = code;
  }
}

function tuyaMessage(code, msg) {
  switch (code) {
    case 1004:
      return L('Tuya godtog inte signaturen. Kontrollera Access ID och Access Secret.',
        'Tuya rejected the signature. Check the Access ID and Access Secret.');
    case 1106:
    case 28841105:
      return L('Molnprojektet saknar behörighet till API:et. Kontrollera att IoT Core är aktiverat.',
        "The cloud project isn't authorized for this API. Check that IoT Core is enabled.");
    case 28841002:
      return L('Provperioden för IoT Core har gått ut. Förläng den under Cloud → Cloud Services på platform.tuya.com.',
        'The IoT Core trial has expired. Extend it under Cloud → Cloud Services at platform.tuya.com.');
    default:
      return `${L('Tuya svarade', 'Tuya responded')} ${code}${msg ? `: ${msg}` : ''}`;
  }
}

const EMPTY_SHA256 = crypto.createHash('sha256').update('').digest('hex');

/** Signed request. sign = HMAC-SHA256(client_id + access_token + t + stringToSign), upper-case hex. */
async function tuyaSend(cfg, path, query, token, method = 'GET', body = '') {
  const keys = Object.keys(query).sort();
  const signedUrl = path + (keys.length ? `?${keys.map((k) => `${k}=${query[k]}`).join('&')}` : '');
  const requestUrl = path + (keys.length
    ? `?${keys.map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(query[k])}`).join('&')}` : '');
  const t = String(Date.now());
  const bodyHash = body ? crypto.createHash('sha256').update(body).digest('hex') : EMPTY_SHA256;
  const stringToSign = [method, bodyHash, '', signedUrl].join('\n');
  const sign = crypto.createHmac('sha256', cfg.secret)
    .update(cfg.accessId + token + t + stringToSign).digest('hex').toUpperCase();
  const headers = { client_id: cfg.accessId, t, sign_method: 'HMAC-SHA256', sign, 'User-Agent': 'torpet-el-cloud/1.0' };
  if (token) headers.access_token = token;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(cfg.host + requestUrl, { method, headers, body: body || undefined, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`${L('Tuya svarade HTTP', 'Tuya responded HTTP')} ${res.status}`);
  return res.json();
}

/** The token lives two hours. It's cached in memory and in the table so every run doesn't spend a call on it. */
let memToken;

async function tuyaToken(cfg, force = false) {
  const now = Date.now();
  if (!force) {
    if (memToken?.accessId === cfg.accessId && memToken.expires - now > 60_000) return memToken.value;
    const it = await getItem('TOKEN');
    if (it?.accessId === cfg.accessId && it.expires - now > 60_000) {
      memToken = { accessId: it.accessId, value: it.value, expires: it.expires };
      return it.value;
    }
  }
  const r = await tuyaSend(cfg, '/v1.0/token', { grant_type: '1' }, '');
  if (!r.success) throw new TuyaError(r.code, r.msg);
  memToken = { accessId: cfg.accessId, value: r.result.access_token, expires: now + (r.result.expire_time ?? 3600) * 1000 };
  await db.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: 'TOKEN', sk: 0, ...memToken, ttl: Math.floor(memToken.expires / 1000) + 3600 },
  }));
  return memToken.value;
}

async function tuyaCall(cfg, path, query = {}, method = 'GET', body = '') {
  let r = await tuyaSend(cfg, path, query, await tuyaToken(cfg), method, body);
  // 1010–1012: invalid or expired token. Get a new one and try once more.
  if (!r.success && r.code >= 1010 && r.code <= 1012) {
    r = await tuyaSend(cfg, path, query, await tuyaToken(cfg, true), method, body);
  }
  if (!r.success) throw new TuyaError(r.code, r.msg);
  return r.result;
}

async function tuyaDevices(cfg) {
  const all = [];
  let lastRow;
  do {
    const q = { size: '100' };
    if (lastRow) q.last_row_key = lastRow;
    const page = await tuyaCall(cfg, '/v1.0/iot-01/associated-users/devices', q);
    all.push(...(page.devices ?? []));
    lastRow = page.has_more && page.devices?.length ? page.last_row_key : undefined;
  } while (lastRow && all.length < 1000);
  return all;
}

/** Scale and unit per value, e.g. that cur_power comes in tenths of a watt. */
async function tuyaScales(cfg, id) {
  const r = await tuyaCall(cfg, `/v1.0/devices/${id}/specifications`);
  const out = {};
  for (const s of r.status ?? []) {
    try {
      const v = JSON.parse(s.values ?? '');
      out[s.code] = { unit: v.unit, scale: v.scale };
    } catch { /* no spec for this code */ }
  }
  return out;
}

/** Standard socket codes: switch_1, cur_power (W, scale 1), cur_voltage (V, scale 1), cur_current (mA). */
function toPlug(d, scales) {
  const st = {};
  for (const s of d.status ?? []) if (!(s.code in st)) st[s.code] = s.value;
  const num = (v) => (typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v)) ? Number(v) : null);
  const bool = (v) => (typeof v === 'boolean' ? v : v === 'true' ? true : v === 'false' ? false : null);
  const scaled = (code, def) => {
    const raw = num(st[code]);
    return raw == null ? null : raw / 10 ** (scales[code]?.scale ?? def);
  };
  let amps = scaled('cur_current', 0);
  if (amps != null && (scales.cur_current?.unit ?? 'mA').toLowerCase() === 'ma') amps /= 1000;
  return {
    id: d.id,
    name: d.name ?? d.id,
    product: d.product_name ?? null,
    online: d.online ?? false,
    isOn: bool(st.switch_1) ?? bool(st.switch),
    switchCode: 'switch_1' in st ? 'switch_1' : 'switch' in st ? 'switch' : null,
    power: scaled('cur_power', 1),
    voltage: scaled('cur_voltage', 1),
    current: amps,
  };
}

// MARK: - Alarm

function defaultWatch(name) {
  const n = (name ?? '').toLowerCase();
  return { enabled: n.includes('frys') || n.includes('freez'), minWatts: 10, hours: 3, offlineAlarm: true, offlineMinutes: 30 };
}

/** One step of Alarm.evaluate: updates the periods with a new reading. */
function step(state, plug, watch, now) {
  if (state.prev && now - state.prev > MAX_GAP) {
    state.idleSince = null;
    state.offlineSince = null;
  }
  state.prev = now;
  if (!plug.online) {
    state.offlineSince ??= now;
    state.idleSince = null; // offline gives no readings, so that time doesn't count as without power
  } else {
    state.offlineSince = null;
    if (plug.power != null) {
      if (plug.power >= watch.minWatts) {
        state.lastActive = now;
        state.idleSince = null;
      } else {
        state.idleSince ??= now;
      }
    }
  }
  return {
    idle: !!(watch.enabled && state.idleSince != null && now - state.idleSince >= watch.hours * 3600),
    offline: !!(watch.enabled && watch.offlineAlarm && state.offlineSince != null
      && now - state.offlineSince >= watch.offlineMinutes * 60),
  };
}

/** Sends one notification when an alarm starts and one when it ends. A failed send is retried next run. */
async function transition(cfg, meta, key, active, alarm, recovered) {
  if (active && !meta.alarms[key]) {
    if (await notify(cfg, { ...alarm, priority: 5, tags: ['warning'] })) meta.alarms[key] = Math.floor(Date.now() / 1000);
  } else if (!active && meta.alarms[key]) {
    if (!recovered || await notify(cfg, { ...recovered, priority: 3, tags: ['white_check_mark'] })) delete meta.alarms[key];
  }
}

async function notify(cfg, { title, body, priority = 3, tags = [] }) {
  if (!cfg.ntfyTopic) {
    console.warn('ntfy-topic is missing in Parameter Store; no notification sent:', title);
    return false;
  }
  const headers = { 'Content-Type': 'application/json' };
  if (cfg.ntfyToken) headers.Authorization = `Bearer ${cfg.ntfyToken}`;
  try {
    const res = await fetch(cfg.ntfyServer, {
      method: 'POST',
      headers,
      body: JSON.stringify({ topic: cfg.ntfyTopic, title, message: body || title, priority, tags }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      console.error('ntfy', res.status, await res.text());
      return false;
    }
    return true;
  } catch (e) {
    console.error('ntfy', e);
    return false;
  }
}

// MARK: - Trial reminder

/** Days before the IoT Core trial ends to send a reminder. Tuya has no API to extend it, so it's done by hand. */
const TRIAL_REMIND_DAYS = [14, 3, 0];

/** One reminder per step in TRIAL_REMIND_DAYS, in daytime only. A new date (after extending) starts over. */
async function trialReminder(cfg, meta) {
  const date = cfg.trialExpires;
  if (!date) return;
  const now = new Date();
  const hour = Number(new Intl.DateTimeFormat('sv-SE', { timeZone: TZ, hour: '2-digit', hourCycle: 'h23' }).format(now));
  if (hour < 9 || hour >= 21) return;
  const today = now.toLocaleDateString('sv-SE', { timeZone: TZ });
  const daysLeft = Math.round((Date.parse(date) - Date.parse(today)) / 86_400_000);
  if (daysLeft < 0) return; // already expired: the "no readings" alarm takes over
  const step = Math.min(...TRIAL_REMIND_DAYS.filter((d) => daysLeft <= d));
  if (!Number.isFinite(step)) return;
  if (meta.trialReminder?.date === date && meta.trialReminder.step <= step) return;
  const when = daysLeft === 0 ? L('idag', 'today')
    : daysLeft === 1 ? L('imorgon', 'tomorrow') : L(`om ${daysLeft} dagar`, `in ${daysLeft} days`);
  const ok = await notify(cfg, {
    title: L(`Provperioden för IoT Core går ut ${when}`, `The IoT Core trial expires ${when}`),
    body: L(`Den går ut ${date}. Förläng den under Cloud → Cloud Services på https://platform.tuya.com och spara sedan det nya datumet med ./setup-params.sh.`,
      `It expires on ${date}. Extend it under Cloud → Cloud Services at https://platform.tuya.com, then save the new date with ./setup-params.sh.`),
    priority: 4,
    tags: ['calendar'],
  });
  if (ok) meta.trialReminder = { date, step };
}

// MARK: - Formatting

const TZ = 'Europe/Stockholm';

function fmtTime(sec) {
  const d = new Date(sec * 1000);
  const locale = lang === 'en' ? 'en-GB' : 'sv-SE';
  const day = (x) => x.toLocaleDateString('sv-SE', { timeZone: TZ });
  const time = d.toLocaleTimeString(locale, { timeZone: TZ, hour: '2-digit', minute: '2-digit' });
  if (day(d) === day(new Date())) return time;
  return `${d.toLocaleDateString(locale, { timeZone: TZ, day: 'numeric', month: 'short' })} ${time}`;
}

function fmtWatts(w) {
  if (w == null) return '–';
  const locale = lang === 'en' ? 'en-GB' : 'sv-SE';
  return `${w.toLocaleString(locale, { maximumFractionDigits: w < 10 ? 1 : 0 })} W`;
}

// MARK: - Table
//
// META  / 0   devices: names, scales, latest values and alarm periods; alarms: which alarms were sent
// WATCH#<id> / 0   alarm settings for a plug (written by the Mac app, so they're kept apart from META)
// S#<id> / <unix seconds>   one reading, deleted by TTL after KEEP_DAYS
// TOKEN / 0   cached Tuya token

async function getItem(pk) {
  return (await db.send(new GetCommand({ TableName: TABLE, Key: { pk, sk: 0 } }))).Item;
}

async function putItem(item) {
  await db.send(new PutCommand({ TableName: TABLE, Item: item }));
}

async function loadWatches(ids, names) {
  const out = {};
  for (let i = 0; i < ids.length; i += 100) {
    const keys = ids.slice(i, i + 100).map((id) => ({ pk: `WATCH#${id}`, sk: 0 }));
    let req = { [TABLE]: { Keys: keys } };
    while (req && Object.keys(req).length) {
      const r = await db.send(new BatchGetCommand({ RequestItems: req }));
      for (const it of r.Responses?.[TABLE] ?? []) out[it.pk.slice(6)] = it.watch;
      req = r.UnprocessedKeys;
    }
  }
  for (const id of ids) {
    if (out[id]) continue;
    out[id] = defaultWatch(names[id]);
    try {
      await db.send(new PutCommand({
        TableName: TABLE,
        Item: { pk: `WATCH#${id}`, sk: 0, watch: out[id] },
        ConditionExpression: 'attribute_not_exists(pk)',
      }));
    } catch (e) {
      if (e.name !== 'ConditionalCheckFailedException') throw e;
    }
  }
  return out;
}

async function writeAll(items) {
  for (let i = 0; i < items.length; i += 25) {
    let req = { [TABLE]: items.slice(i, i + 25).map((Item) => ({ PutRequest: { Item } })) };
    for (let attempt = 0; req && Object.keys(req).length; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 200 * 2 ** attempt));
      if (attempt > 5) throw new Error('DynamoDB kept throttling the readings');
      const r = await db.send(new BatchWriteCommand({ RequestItems: req }));
      req = r.UnprocessedItems;
    }
  }
}

// MARK: - Poll (every five minutes)

async function poll() {
  const cfg = await config();
  lang = cfg.lang;
  if (!cfg.accessId || !cfg.secret || !cfg.host) {
    console.error(`Tuya credentials are missing under ${PARAM_PATH} in Parameter Store`);
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  const meta = (await getItem('META')) ?? { pk: 'META', sk: 0 };
  meta.devices ??= {};
  meta.alarms ??= {};
  await trialReminder(cfg, meta);

  let list;
  try {
    list = await tuyaDevices(cfg);
  } catch (e) {
    console.error('Tuya:', e.message);
    meta.tuyaError = e.message;
    meta.tuyaFailingSince ??= now;
    await transition(cfg, meta, 'tuya', now - meta.tuyaFailingSince >= TUYA_FAIL_ALARM, {
      title: L('Torpet El får inga mätningar', 'Torpet El gets no readings'),
      body: L(`Inget svar från Tuya sedan ${fmtTime(meta.tuyaFailingSince)}. ${e.message}`,
        `No answer from Tuya since ${fmtTime(meta.tuyaFailingSince)}. ${e.message}`),
    });
    await putItem(meta);
    return;
  }
  meta.tuyaError = null;
  meta.tuyaFailingSince = null;
  await transition(cfg, meta, 'tuya', false, null, {
    title: L('Torpet El får mätningar igen', 'Torpet El gets readings again'),
    body: L('Tuya svarar som vanligt igen.', 'Tuya is answering again.'),
  });

  const names = Object.fromEntries(list.map((d) => [d.id, d.name ?? d.id]));
  const watches = await loadWatches(list.map((d) => d.id), names);
  const samples = [];
  const ttl = now + KEEP_DAYS * 86_400;

  for (const d of list) {
    const dev = (meta.devices[d.id] ??= { state: {} });
    if (!dev.scales) {
      // Without a spec the standard scales are used; try again next run.
      try { dev.scales = await tuyaScales(cfg, d.id); } catch (e) { console.warn('specifications', d.id, e.message); }
    }
    const p = toPlug(d, dev.scales ?? {});
    const watch = watches[d.id];
    Object.assign(dev, { name: p.name, product: p.product, latest: p });
    const a = step(dev.state, p, watch, now);
    samples.push({
      pk: `S#${p.id}`, sk: now, online: p.online, isOn: p.isOn, power: p.power, voltage: p.voltage, current: p.current, ttl,
    });

    if (!watch.enabled) {
      delete meta.alarms[`${p.id}|idle`];
      delete meta.alarms[`${p.id}|offline`];
      continue;
    }
    // An offline plug says nothing about power, so it neither raises nor clears the power alarm.
    if (p.online) {
      await transition(cfg, meta, `${p.id}|idle`, a.idle, {
        title: L(`${p.name}: ingen ström`, `${p.name}: no power`),
        body: L(`Har inte dragit över ${fmtWatts(watch.minWatts)} sedan ${fmtTime(dev.state.idleSince)}. Kontrollera frysen.`,
          `Hasn't drawn more than ${fmtWatts(watch.minWatts)} since ${fmtTime(dev.state.idleSince)}. Check the freezer.`),
      }, {
        title: L(`${p.name} drar ström igen`, `${p.name} is drawing power again`),
        body: L(`Just nu ${fmtWatts(p.power)}.`, `Currently ${fmtWatts(p.power)}.`),
      });
    }
    await transition(cfg, meta, `${p.id}|offline`, a.offline, {
      title: L(`${p.name} är offline`, `${p.name} is offline`),
      body: L(`Ingen kontakt sedan ${fmtTime(dev.state.offlineSince)}. Strömavbrott, utlöst säkring eller nätverket på torpet?`,
        `No contact since ${fmtTime(dev.state.offlineSince)}. Power cut, tripped fuse or the network at the cottage?`),
    }, {
      title: L(`${p.name} är online igen`, `${p.name} is back online`),
      body: L(`Just nu ${fmtWatts(p.power)}.`, `Currently ${fmtWatts(p.power)}.`),
    });
  }

  await writeAll(samples);
  meta.fetchedAt = now;
  await putItem(meta);
  console.log(`Saved ${samples.length} readings; active alarms: ${Object.keys(meta.alarms).join(', ') || 'none'}`);
}

// MARK: - HTTP API for the Mac app

function json(statusCode, body) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
}

function authorized(cfg, header) {
  if (!cfg.apiKey || !header) return false;
  const a = Buffer.from(header);
  const b = Buffer.from(`Bearer ${cfg.apiKey}`);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parseWatch(body) {
  const w = typeof body === 'object' && body ? body : {};
  const n = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
  if (typeof w.enabled !== 'boolean' || typeof w.offlineAlarm !== 'boolean'
    || !n(w.minWatts, 0, 5000) || !n(w.hours, 0.1, 240) || !n(w.offlineMinutes, 1, 10_080)) return null;
  return { enabled: w.enabled, minWatts: w.minWatts, hours: w.hours, offlineAlarm: w.offlineAlarm, offlineMinutes: w.offlineMinutes };
}

async function http(event) {
  let cfg = await config();
  if (!authorized(cfg, event.headers?.authorization)) {
    // The key may have been set or changed since the settings were cached.
    cfgCache = null;
    cfg = await config();
    if (!authorized(cfg, event.headers?.authorization)) return json(401, { error: 'unauthorized' });
  }
  lang = cfg.lang;
  const method = event.requestContext.http.method;
  const path = event.rawPath.replace(/\/+$/, '') || '/';
  const now = Math.floor(Date.now() / 1000);

  if (method === 'GET' && path === '/status') {
    const meta = (await getItem('META')) ?? { devices: {}, alarms: {} };
    const ids = Object.keys(meta.devices ?? {});
    const watches = ids.length ? await loadWatches(ids, Object.fromEntries(ids.map((id) => [id, meta.devices[id].name]))) : {};
    const plugs = ids.map((id) => {
      const d = meta.devices[id];
      const s = d.state ?? {};
      return {
        ...d.latest,
        watch: watches[id],
        status: {
          idleSince: s.idleSince ?? null,
          lastActive: s.lastActive ?? null,
          offlineSince: s.offlineSince ?? null,
          lastReading: s.prev ?? null,
          fresh: s.prev != null && now - s.prev <= MAX_GAP,
          idleAlarm: !!meta.alarms?.[`${id}|idle`],
          offlineAlarm: !!meta.alarms?.[`${id}|offline`],
        },
      };
    }).sort((a, b) => a.name.localeCompare(b.name, 'sv', { numeric: true }));
    return json(200, {
      fetchedAt: meta.fetchedAt ?? null,
      tuyaError: meta.tuyaError ?? null,
      tuyaFailingSince: meta.tuyaFailingSince ?? null,
      trialExpires: cfg.trialExpires,
      plugs,
    });
  }

  if (method === 'GET' && path === '/samples') {
    const q = event.queryStringParameters ?? {};
    if (!q.device) return json(400, { error: 'device is required' });
    const since = Math.max(Number(q.since) || now - 86_400, now - KEEP_DAYS * 86_400);
    const out = [];
    let ExclusiveStartKey;
    do {
      const r = await db.send(new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: 'pk = :pk AND sk >= :since',
        ExpressionAttributeValues: { ':pk': `S#${q.device}`, ':since': since },
        ExclusiveStartKey,
      }));
      for (const it of r.Items ?? []) {
        out.push({ t: it.sk, online: it.online, isOn: it.isOn ?? null, power: it.power ?? null, voltage: it.voltage ?? null, current: it.current ?? null });
      }
      ExclusiveStartKey = r.LastEvaluatedKey;
    } while (ExclusiveStartKey);
    return json(200, { device: q.device, since, samples: out });
  }

  const m = path.match(/^\/watch\/([A-Za-z0-9_-]{1,64})$/);
  if (method === 'PUT' && m) {
    let body;
    try {
      body = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body ?? '', 'base64').toString() : event.body ?? '');
    } catch {
      return json(400, { error: 'body must be JSON' });
    }
    const watch = parseWatch(body);
    if (!watch) return json(400, { error: 'expected {enabled, minWatts, hours, offlineAlarm, offlineMinutes}' });
    await putItem({ pk: `WATCH#${m[1]}`, sk: 0, watch });
    return json(200, { device: m[1], watch });
  }

  const sw = path.match(/^\/switch\/([A-Za-z0-9_-]{1,64})$/);
  if (method === 'POST' && sw) {
    let body;
    try {
      body = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body ?? '', 'base64').toString() : event.body ?? '');
    } catch {
      return json(400, { error: 'body must be JSON' });
    }
    if (typeof body?.on !== 'boolean') return json(400, { error: 'expected {on: true|false}' });
    const meta = await getItem('META');
    const dev = meta?.devices?.[sw[1]];
    if (!dev) return json(404, { error: 'unknown device' });
    const code = dev.latest?.switchCode;
    if (!code) return json(409, { error: 'this device has no switch' });
    try {
      await tuyaCall(cfg, `/v1.0/iot-03/devices/${sw[1]}/commands`, {}, 'POST',
        JSON.stringify({ commands: [{ code, value: body.on }] }));
    } catch (e) {
      return json(502, { error: e.message });
    }
    // Show the new state right away instead of after the next poll.
    await db.send(new UpdateCommand({
      TableName: TABLE,
      Key: { pk: 'META', sk: 0 },
      UpdateExpression: 'SET devices.#id.latest.isOn = :on',
      ExpressionAttributeNames: { '#id': sw[1] },
      ExpressionAttributeValues: { ':on': body.on },
    }));
    console.log(`Switched ${dev.name} ${body.on ? 'on' : 'off'}`);
    return json(200, { device: sw[1], on: body.on });
  }

  if (method === 'POST' && path === '/test') {
    const ok = await notify(cfg, {
      title: 'Torpet El', body: L('Så här ser ett larm ut.', 'This is what an alarm looks like.'), priority: 3, tags: ['bell'],
    });
    return json(ok ? 200 : 502, { sent: ok });
  }

  return json(404, { error: 'not found' });
}

export const handler = async (event) => (event?.requestContext?.http ? http(event) : poll());
