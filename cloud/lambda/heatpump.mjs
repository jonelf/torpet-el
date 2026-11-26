// MELCloud Home: reads the air-to-air heat pump(s) every poll and saves readings next to the Tuya ones.
//
// Kept apart from the freezer path in index.mjs: the library is imported only when a poll gets here and every
// failure ends up in the HP item, so a MELCloud outage can never stop the freezer alarms.
//
// Table items (see index.mjs for the rest):
//   HP / 0                  units: name, latest values; fetchedAt, error, failingSince, energyAt
//   MELCLOUD / 0            the library's session (tokens, expiry). Never the password: that stays in Parameter Store.
//   H#<unit id> / <unix s>  one reading, deleted by TTL
//   E#<unit id> / <unix s>  energy used in the hour that starts at sk, in kWh, deleted by TTL

const TZ = 'Europe/Stockholm';
/** The login lives in Parameter Store; the library asks for it through the store, but it is never written to the table. */
const SECRET_KEYS = new Set(['username', 'password']);
/** Energy is fetched this often (the wire reports hourly), and this far back each time: the latest hour is still partial. */
const ENERGY_EVERY = 50 * 60;
const ENERGY_BACK = 4 * 3600;
const ENERGY_FIRST_BACK = 86_400;

/** A string store for the library's session, backed by one table item. Written back only when something changed. */
function sessionStore(saved, login) {
  const map = new Map(Object.entries(saved ?? {}));
  let dirty = false;
  return {
    manager: {
      get: (key) => (SECRET_KEYS.has(key) ? login[key] : map.get(key)),
      set: (key, value) => {
        if (SECRET_KEYS.has(key) || map.get(key) === value) return;
        map.set(key, value);
        dirty = true;
      },
      unset: (key) => {
        if (!SECRET_KEYS.has(key) && map.delete(key)) dirty = true;
      },
    },
    changed: () => (dirty ? Object.fromEntries(map) : null),
  };
}

const value = (r) => (r?.ok ? r.value : null);

// MARK: - Alarms
//
// The pipes must not freeze, so the main alarm is the room temperature on the unit's own thermometer. A reading that is
// merely low is not enough (the unit's reading jumps as it starts and stops): it has to stay low for `minutes`.

/** A longer gap between readings restarts the counting, as for the freezers: we don't know what happened meanwhile. */
const MAX_GAP = 20 * 60;
/** Alarm when MELCloud has been unreadable this long: the pipes are then out of sight. */
const NODATA_ALARM = 60 * 60;
/** The room has to climb this far above the limit before a cold alarm counts as over, so it doesn't flap. */
const HYSTERESIS = 0.5;

export function defaultHeatWatch() {
  return { enabled: true, lowC: 10, warnC: 11, minutes: 30, errorAlarm: true, offlineMinutes: 30 };
}

export function parseHeatWatch(body) {
  const w = typeof body === 'object' && body ? body : {};
  const n = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
  if (typeof w.enabled !== 'boolean' || typeof w.errorAlarm !== 'boolean' || !n(w.lowC, 0, 20) || !n(w.warnC, 0, 25)
    || w.warnC < w.lowC || !n(w.minutes, 5, 720) || !n(w.offlineMinutes, 5, 10_080)) return null;
  return { enabled: w.enabled, lowC: w.lowC, warnC: w.warnC, minutes: w.minutes, errorAlarm: w.errorAlarm, offlineMinutes: w.offlineMinutes };
}

/** One step of the alarm rules: updates the periods with a new reading. */
export function stepUnit(state, u, w, now) {
  if (state.prev && now - state.prev > MAX_GAP) {
    state.coldSince = null;
    state.warnSince = null;
    state.offlineSince = null;
  }
  state.prev = now;
  const room = u.room;
  const low = room != null && (room < w.lowC || (state.coldSince != null && room < w.lowC + HYSTERESIS));
  state.coldSince = low ? (state.coldSince ?? now) : null;
  state.warnSince = room != null && room < w.warnC ? (state.warnSince ?? now) : null;
  state.offlineSince = u.connected === false ? (state.offlineSince ?? now) : null;
  const held = (since, minutes) => since != null && now - since >= minutes * 60;
  const cold = held(state.coldSince, w.minutes);
  return {
    cold,
    // A warning is the step before the alarm, so it gives way to it.
    cool: !cold && held(state.warnSince, w.minutes),
    offline: held(state.offlineSince, w.offlineMinutes),
    error: w.errorAlarm && u.inError === true,
  };
}

const deg = (v, locale) => `${v.toLocaleString(locale, { maximumFractionDigits: 1 })} °C`;

/** What the app shows of one unit. */
async function readUnit(f) {
  const frost = value(await f.getFrostProtection());
  return {
    id: f.id,
    name: f.name,
    power: f.power,
    mode: f.operationMode ?? null,
    room: f.roomTemperature ?? null,
    set: f.setTemperature ?? null,
    fan: f.setFanSpeed ?? null,
    rssi: f.rssi ?? null,
    connected: f.isConnected,
    available: f.isAvailable,
    standby: f.inStandbyMode,
    inError: f.isInError,
    error: f.isInError ? f.errorMessage : null,
    step: f.temperatureStep ?? null,
    minHeat: f.capabilities?.minTempHeat ?? null,
    maxHeat: f.capabilities?.maxTempHeat ?? null,
    frost,
  };
}

/** Opens the library on the saved session. Throws when it can't sign in. */
async function connect(session) {
  const lib = await import('@olivierzal/melcloud-api');
  const api = await lib.HomeAPI.create({
    settingManager: session.manager,
    syncIntervalMinutes: false, // one poll is one read; the next poll is five minutes away
    timezone: TZ,
    // The library logs every request. Keep failures, drop the chatter, so the log stays readable.
    logger: { log: () => {}, error: (...a) => console.error(...a) },
  });
  if (!api.isAuthenticated()) throw new Error(api.isRateLimited ? 'MELCloud is rate limiting' : 'MELCloud sign-in failed');
  return { lib, api, manager: new lib.HomeFacadeManager(api) };
}

async function makeSession(cfg, getItem) {
  return sessionStore((await getItem('MELCLOUD'))?.settings, { username: cfg.melcloudUser, password: cfg.melcloudPassword });
}

/** The session is saved even after a failure: a token that was just renewed saves the next sign-in. */
async function saveSession(session, putItem) {
  const settings = session.changed();
  if (settings) await putItem({ pk: 'MELCLOUD', sk: 0, settings }).catch((e) => console.error('MELCLOUD session:', e));
}

/**
 * The unit as the app shows it, holiday mode included. `device` is the registry's own record: MELCloud's `active` flag
 * for frost protection is only there. While it is on, MELCloud ignores changes to the target temperature.
 */
async function snapshot(f, device) {
  const u = await readUnit(f);
  if (u.frost) u.frost = { ...u.frost, active: device?.data?.frostProtection?.active === true };
  const holiday = value(await f.getHolidayMode());
  u.holiday = holiday?.isEnabled ? holiday : null; // the dates of a switched-off holiday say nothing
  return u;
}

// MARK: - Control

const MODES = new Set(['Heat', 'Cool', 'Auto', 'Dry', 'Fan']);
const FANS = new Set(['Auto', 'One', 'Two', 'Three', 'Four', 'Five']);
const num = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
const wallClock = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(v);

/**
 * Checks a write from the app. Returns what to do with the unit, or `{ error }`.
 * `kind` is `set` (power, mode, target, fan), `frost` or `holiday`.
 */
export function parseHeatCommand(kind, body, latest) {
  const b = typeof body === 'object' && body ? body : {};
  if (kind === 'set') {
    const values = {};
    if (b.power !== undefined) { if (typeof b.power !== 'boolean') return { error: 'power must be true or false' }; values.power = b.power; }
    if (b.operationMode !== undefined) { if (!MODES.has(b.operationMode)) return { error: 'unknown operationMode' }; values.operationMode = b.operationMode; }
    if (b.setFanSpeed !== undefined) { if (!FANS.has(b.setFanSpeed)) return { error: 'unknown setFanSpeed' }; values.setFanSpeed = b.setFanSpeed; }
    if (b.setTemperature !== undefined) {
      if (!num(b.setTemperature, latest?.minHeat ?? 10, latest?.maxHeat ?? 31)) return { error: 'setTemperature is outside what the unit accepts' };
      values.setTemperature = b.setTemperature;
    }
    if (!Object.keys(values).length) return { error: 'nothing to change' };
    return { label: `set ${JSON.stringify(values)}`, apply: (f) => f.updateValues(values) };
  }
  if (kind === 'frost') {
    if (typeof b.isEnabled !== 'boolean' || !num(b.min, 4, 16) || !num(b.max, 4, 16) || b.max < b.min + 2) {
      return { error: 'expected {isEnabled, min, max}: 4 to 16 °C, at least 2 °C apart' };
    }
    const update = { isEnabled: b.isEnabled, min: b.min, max: b.max };
    return { label: `frost ${JSON.stringify(update)}`, apply: (f) => f.updateFrostProtection(update) };
  }
  if (typeof b.isEnabled !== 'boolean' || (b.isEnabled && (!wallClock(b.startDate) || !wallClock(b.endDate) || b.endDate <= b.startDate))) {
    return { error: 'expected {isEnabled, startDate, endDate} as local times, the end after the start' };
  }
  // The dates are ignored when holiday mode is switched off.
  const now = new Date().toLocaleString('sv-SE', { timeZone: TZ }).replace(' ', 'T');
  const update = { isEnabled: b.isEnabled, startDate: b.startDate ?? now, endDate: b.endDate ?? now };
  return { label: `holiday ${JSON.stringify(update)}`, apply: (f) => f.updateHolidayMode(update) };
}

/** Runs a write on one unit, and returns the unit's state afterwards. Throws; `status` on the error says what to answer. */
export async function controlHeatPump({ cfg, getItem, putItem }, id, command) {
  if (!cfg.melcloudUser || !cfg.melcloudPassword) throw Object.assign(new Error('no MELCloud login is saved'), { status: 409 });
  const session = await makeSession(cfg, getItem);
  let api;
  try {
    const c = await connect(session);
    api = c.api;
    const device = c.api.registry.getDevicesByType(c.lib.HomeDeviceType.Ata).find((d) => c.manager.get(d).id === id);
    const f = device && c.manager.get(device);
    if (!f) throw Object.assign(new Error('unknown unit'), { status: 404 });
    try {
      await command.apply(f);
    } catch (e) {
      // Nothing to change is not a failure: the unit already is as asked.
      if (!(e instanceof c.lib.NoChangesError)) throw e;
    }
    console.log(`Heat pump ${command.label}`);
    return await snapshot(f, device);
  } catch (e) {
    console.error('MELCloud write:', e);
    if (e?.status) throw e;
    throw Object.assign(new Error(e instanceof Error ? e.message : String(e)), { status: 502 });
  } finally {
    try { api?.[Symbol.dispose]?.(); } catch { /* nothing to clean up */ }
    await saveSession(session, putItem);
  }
}

/**
 * Returns nothing and never throws. `ctx` carries what index.mjs owns: the settings, the table helpers and the clock.
 */
export async function pollHeatPump({ cfg, now, ttl, getItem, putItem, writeAll, alarm }) {
  const { transition, L, fmtTime } = alarm;
  if (!cfg.melcloudUser || !cfg.melcloudPassword) return;

  const hp = (await getItem('HP')) ?? { pk: 'HP', sk: 0 };
  hp.units ??= {};
  const session = await makeSession(cfg, getItem);

  let api;
  try {
    const c = await connect(session);
    api = c.api;
    const { lib: { HomeDeviceType }, manager } = c;
    const samples = [];
    const seen = new Set();
    for (const device of api.registry.getDevicesByType(HomeDeviceType.Ata)) {
      const f = manager.get(device);
      const u = await snapshot(f, device);
      seen.add(u.id);
      hp.units[u.id] = { ...(hp.units[u.id] ?? {}), name: u.name, latest: u };
      hp.alarms ??= {};
      const watch = (await getItem(`HPWATCH#${u.id}`))?.watch ?? defaultHeatWatch();
      const state = (hp.units[u.id].state ??= {});
      const a = stepUnit(state, u, watch, now);
      const sv = { Heat: 'värme', Cool: 'kyla', Auto: 'auto', Dry: 'avfuktning', Fan: 'fläkt' };
      const state_ = u.power
        ? L(` Pumpen är på (${sv[u.mode] ?? u.mode}, mål ${deg(u.set ?? 0, 'sv-SE')}).`, ` The unit is on (${(u.mode ?? '').toLowerCase()}, target ${deg(u.set ?? 0, 'en-GB')}).`)
        : L(' Pumpen är avslagen.', ' The unit is switched off.');
      if (!watch.enabled) {
        for (const k of ['cold', 'cool', 'error', 'offline']) delete hp.alarms[`${u.id}|${k}`];
      } else {
        await transition(cfg, hp, `${u.id}|cold`, a.cold, {
          title: L(`${u.name}: kallt på torpet`, `${u.name}: cold at the cottage`),
          body: L(`${deg(u.room, 'sv-SE')} sedan ${fmtTime(state.coldSince)} (gräns ${deg(watch.lowC, 'sv-SE')}). Vattenrören kan frysa.${state_}`,
            `${deg(u.room, 'en-GB')} since ${fmtTime(state.coldSince)} (limit ${deg(watch.lowC, 'en-GB')}). The water pipes may freeze.${state_}`),
        }, {
          title: L(`${u.name}: varmare igen`, `${u.name}: warming up again`),
          body: L(`Just nu ${deg(u.room ?? 0, 'sv-SE')}.`, `Currently ${deg(u.room ?? 0, 'en-GB')}.`),
        });
        // The step before the alarm. It is sent quietly and without a follow-up.
        await transition(cfg, hp, `${u.id}|cool`, a.cool, {
          title: L(`${u.name}: svalnar`, `${u.name}: getting cool`),
          body: L(`${deg(u.room, 'sv-SE')}, under ${deg(watch.warnC, 'sv-SE')} sedan ${fmtTime(state.warnSince)}.${state_}`,
            `${deg(u.room, 'en-GB')}, below ${deg(watch.warnC, 'en-GB')} since ${fmtTime(state.warnSince)}.${state_}`),
        }, null, { priority: 3, tags: ['thermometer'] });
        await transition(cfg, hp, `${u.id}|error`, a.error, {
          title: L(`${u.name}: fel`, `${u.name}: fault`),
          body: u.error || L('Värmepumpen rapporterar ett fel.', 'The heat pump reports a fault.'),
        }, {
          title: L(`${u.name}: felet är borta`, `${u.name}: the fault is gone`), body: '',
        });
        await transition(cfg, hp, `${u.id}|offline`, a.offline, {
          title: L(`${u.name} är offline`, `${u.name} is offline`),
          body: L(`Ingen kontakt sedan ${fmtTime(state.offlineSince)}. Wi-Fi eller strömmen på torpet? Rumstemperaturen går inte att se.`,
            `No contact since ${fmtTime(state.offlineSince)}. Wi-Fi or power at the cottage? The room temperature can't be seen.`),
        }, {
          title: L(`${u.name} är online igen`, `${u.name} is back online`), body: '',
        });
      }
      samples.push({
        pk: `H#${u.id}`, sk: now, room: u.room, set: u.set, mode: u.mode, power: u.power, rssi: u.rssi,
        connected: u.connected, error: u.error, ttl,
      });

      if (!hp.energyAt || now - hp.energyAt >= ENERGY_EVERY) {
        const from = now - (hp.energyAt ? ENERGY_BACK : ENERGY_FIRST_BACK);
        const series = value(await f.getEnergySeries({
          from: new Date(from * 1000).toISOString(),
          to: new Date(now * 1000).toISOString(),
        }));
        const rows = (series?.consumed ?? [])
          .filter((p) => p.kilowattHours != null)
          .map((p) => ({ pk: `E#${u.id}`, sk: Math.floor(p.atEpochMs / 1000), kwh: p.kilowattHours, ttl }));
        if (series) {
          await writeAll(rows);
          hp.energyAt = now;
        }
      }
    }
    for (const id of Object.keys(hp.units)) if (!seen.has(id)) delete hp.units[id]; // a unit that left the account
    await writeAll(samples);
    hp.fetchedAt = now;
    hp.error = null;
    hp.failingSince = null;
    await transition(cfg, hp, 'hp|nodata', false, null, {
      title: L('Värmepumpen går att läsa igen', 'The heat pump can be read again'), body: '',
    });
    console.log(`Saved ${samples.length} heat pump reading(s)`);
  } catch (e) {
    console.error('MELCloud:', e);
    hp.error = e instanceof Error ? e.message : String(e);
    hp.failingSince ??= now;
    hp.alarms ??= {};
    // Without readings the temperature can't be watched. Only worth an alarm once a unit has been seen.
    if (Object.keys(hp.units).length) {
      await transition(cfg, hp, 'hp|nodata', now - hp.failingSince >= NODATA_ALARM, {
        title: L('Går inte att läsa värmepumpen', "Can't read the heat pump"),
        body: L(`Inget svar från MELCloud sedan ${fmtTime(hp.failingSince)}, så temperaturen på torpet syns inte. ${hp.error}`,
          `No answer from MELCloud since ${fmtTime(hp.failingSince)}, so the cottage temperature can't be seen. ${hp.error}`),
      }, null).catch((err) => console.error('hp|nodata', err));
    }
  } finally {
    try { api?.[Symbol.dispose]?.(); } catch { /* nothing to clean up */ }
    await saveSession(session, putItem);
    await putItem(hp).catch((e) => console.error('HP item:', e));
  }
}
