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
const ENERGY_FIRST_BACK = 3 * 86_400;

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

/**
 * Returns nothing and never throws. `ctx` carries what index.mjs owns: the settings, the table helpers and the clock.
 */
export async function pollHeatPump({ cfg, now, ttl, getItem, putItem, writeAll }) {
  if (!cfg.melcloudUser || !cfg.melcloudPassword) return;

  const hp = (await getItem('HP')) ?? { pk: 'HP', sk: 0 };
  hp.units ??= {};
  const session = sessionStore((await getItem('MELCLOUD'))?.settings, {
    username: cfg.melcloudUser,
    password: cfg.melcloudPassword,
  });

  let api;
  try {
    const { HomeAPI, HomeDeviceType, HomeFacadeManager } = await import('@olivierzal/melcloud-api');
    api = await HomeAPI.create({
      settingManager: session.manager,
      syncIntervalMinutes: false, // one poll is one read; the next poll is five minutes away
      timezone: TZ,
      // The library logs every request. Keep failures, drop the chatter, so the log stays readable.
      logger: { log: () => {}, error: (...a) => console.error(...a) },
    });
    if (!api.isAuthenticated()) throw new Error(api.isRateLimited ? 'MELCloud is rate limiting' : 'MELCloud sign-in failed');

    const manager = new HomeFacadeManager(api);
    const samples = [];
    const seen = new Set();
    for (const device of api.registry.getDevicesByType(HomeDeviceType.Ata)) {
      const f = manager.get(device);
      const u = await readUnit(f);
      seen.add(u.id);
      const holiday = value(await f.getHolidayMode());
      u.holiday = holiday?.isEnabled ? holiday : null; // the dates of a switched-off holiday say nothing
      hp.units[u.id] = { ...(hp.units[u.id] ?? {}), name: u.name, latest: u };
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
    console.log(`Saved ${samples.length} heat pump reading(s)`);
  } catch (e) {
    console.error('MELCloud:', e);
    hp.error = e instanceof Error ? e.message : String(e);
    hp.failingSince ??= now;
  } finally {
    try { api?.[Symbol.dispose]?.(); } catch { /* nothing to clean up */ }
    // The session is saved even after a failure: a token that was just renewed saves the next sign-in.
    const settings = session.changed();
    if (settings) await putItem({ pk: 'MELCLOUD', sk: 0, settings }).catch((e) => console.error('MELCLOUD session:', e));
    await putItem(hp).catch((e) => console.error('HP item:', e));
  }
}
