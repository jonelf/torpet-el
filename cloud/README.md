# Torpet El in the cloud

An AWS Lambda that does what the Mac app does, but around the clock: every five minutes it fetches the plugs from
Tuya, saves the readings in DynamoDB and sends alarms to your phone through [ntfy](https://ntfy.sh). The Mac app can
read status and charts from it instead of polling Tuya itself.

Everything runs in **eu-north-1** within AWS's Always Free tier: EventBridge Scheduler, about 8,600 Lambda runs a
month, a DynamoDB table with 5 read and 2 write units provisioned, Parameter Store (standard), and logs kept for 14 days.

## Setup

```bash
aws login --profile personal   # the IAM user jonelf
./setup-params.sh              # Tuya keys, ntfy topic and API key into Parameter Store
./deploy.sh                    # stack + function code, prints the Function URL
```

Subscribe to the ntfy topic that `setup-params.sh` prints, in the ntfy app on your phone. Test it with:

```bash
curl -X POST -H "Authorization: Bearer <api-key>" <function-url>test
```

On iPhone, a Focus such as Sleep or Do Not Disturb holds notifications back, so a freezer alarm at night only
shows up once you open the ntfy app. To let the alarms through, open **Settings → Focus → Sleep → Apps → Add** and
pick **ntfy**, and do the same for any other Focus you use. The ring/silent switch still applies: with the phone on
silent the alarm shows on the lock screen but makes no sound. Install the app named **ntfy** by Philipp Heckel,
the author of ntfy.

To change the code, edit `lambda/index.mjs` and run `./deploy.sh` again. Logs: `aws logs tail /aws/lambda/torpet-el --follow --profile personal`.

## Alarms

Same rules as the app: below `minWatts` for `hours` of observed readings, or offline for `offlineMinutes`. A gap
of more than 20 minutes between readings restarts the count. One notification is sent when an alarm starts and one
when it ends. If Tuya fails for 30 minutes (for example when the IoT Core trial has expired), that alarms too.

Tuya has no API for extending the IoT Core trial, so it has to be done by hand in the console. To get a warning
before it lapses, save the expiry date as `tuya-trial-expires` (`./setup-params.sh` asks for it). The function then
sends an ntfy reminder 14, 3 and 0 days before, between 09 and 21 Swedish time. After extending, save the new date
and the reminders start over:

```bash
aws ssm put-parameter --name /torpet-el/tuya-trial-expires --type String --overwrite --value 2027-05-01 --profile personal
```

Differences from the app:
- The alarm periods are built up one reading at a time, so changed settings apply from the next reading instead of
  being recalculated over earlier readings.
- An offline plug never clears the power alarm. The alarm clears only when the plug draws power again.

## Parameter Store (`/torpet-el/…`)

| Name | Type | Contents |
|---|---|---|
| `tuya-access-id` | String | Access ID of the Tuya cloud project |
| `tuya-access-secret` | SecureString | Access Secret |
| `tuya-region` | String | `centralEurope` (default), `westernEurope`, … or a full host URL |
| `ntfy-topic` | SecureString | Topic name; whoever knows it can read the alarms |
| `ntfy-server`, `ntfy-token` | optional | Your own ntfy server and its access token |
| `api-key` | SecureString | Key the Mac app sends as `Authorization: Bearer <key>` |
| `language` | optional | `en` for English notifications, Swedish otherwise |
| `tuya-trial-expires` | optional | `YYYY-MM-DD` when the IoT Core trial ends; reminders are sent 14, 3 and 0 days before |

## API for the Mac app

Base URL: the Function URL that `deploy.sh` prints (`https://<id>.lambda-url.eu-north-1.on.aws/`).

All requests need `Authorization: Bearer <api-key>`. Get the key with
`aws ssm get-parameter --name /torpet-el/api-key --with-decryption --query Parameter.Value --output text --profile personal`.
Times are Unix seconds.

`GET /status`:

```json
{ "fetchedAt": 1793468100, "tuyaError": null, "tuyaFailingSince": null, "trialExpires": "2027-05-01",
  "plugs": [{ "id": "…", "name": "Frysen", "product": "…", "online": true, "isOn": true,
              "power": 84, "voltage": 230.1, "current": 0.37,
              "watch": { "enabled": true, "minWatts": 10, "hours": 3, "offlineAlarm": true, "offlineMinutes": 30 },
              "status": { "idleSince": null, "lastActive": 1793468100, "offlineSince": null, "lastReading": 1793468100,
                          "fresh": true, "idleAlarm": false, "offlineAlarm": false } }] }
```

`GET /samples?device=<id>&since=<unix>` returns `{ "samples": [{ "t", "online", "isOn", "power", "voltage", "current" }] }`.
The default is the last 24 hours, and readings are kept for 90 days.

`PUT /watch/<id>` with body `{ "enabled", "minWatts", "hours", "offlineAlarm", "offlineMinutes" }` saves a plug's alarm settings.

`POST /switch/<id>` with body `{ "on": true|false }` switches a plug on or off through Tuya. The Mac app asks for
confirmation before switching off a watched plug.

`POST /test` sends a test notification.

## Table `TorpetEl`

| pk | sk | Contents |
|---|---|---|
| `META` | 0 | Plugs, latest values, alarm periods, which alarms have been sent |
| `WATCH#<id>` | 0 | Alarm settings per plug |
| `S#<id>` | Unix time | One reading, deleted by TTL |
| `TOKEN` | 0 | Cached Tuya token |

The table is kept if the stack is deleted (`DeletionPolicy: Retain`).
