// Fork-only (phone-hub). GENERATED copy of hub/test/fixtures/phone_payload_v1.json (the R1 wire contract,
// Health Analysis repo, commit e755f3f). Embedded rather than bundled so the host-less test target needs no
// resources. If the contract changes, regenerate this file; the local harness diffs it against the source.
enum HubContractFixture {
    static let phonePayloadV1 = #"""
{
  "schema": 1,
  "device": {
    "app_version": "12.0.0-hub.1",
    "build": "1200",
    "band_fw": "41.16.6.0",
    "band_battery": 81.5,
    "embedded_expiry": 1896379200,
    "tz": "America/Los_Angeles",
    "steps_status": "ok"
  },
  "daily": [
    {
      "day": "2030-01-15",
      "recovery": 67.0,
      "strain": 38.5,
      "resting_hr": 55,
      "avg_hrv": 72.4,
      "avg_sdnn": 88.1,
      "resp_rate_bpm": 14.6,
      "skin_temp_dev_c": -0.12,
      "total_sleep_min": 441.0,
      "efficiency": 91.2,
      "disturbances": 9,
      "exercise_count": 1,
      "steps": 7912,
      "active_kcal_est": 512.3
    }
  ],
  "sleep": [
    {
      "start_ts": 1894691400,
      "end_ts": 1894719720,
      "local_day": "2030-01-14",
      "total_min": 441.0,
      "efficiency": 91.2,
      "resting_hr": 55,
      "avg_hrv": 72.4,
      "is_nap": 0,
      "start_ts_adjusted": null,
      "user_edited": 0
    },
    {
      "start_ts": 1894743000,
      "end_ts": 1894745100,
      "local_day": "2030-01-15",
      "total_min": 31.0,
      "efficiency": 88.6,
      "resting_hr": 58,
      "avg_hrv": 65.0,
      "is_nap": 1,
      "start_ts_adjusted": null,
      "user_edited": 0
    }
  ],
  "hr_minute": [
    { "t": 1894717800, "mean": 54.2, "min": 52, "max": 57, "n": 58 },
    { "t": 1894717860, "mean": 55.0, "min": 53, "max": 58, "n": 60 },
    { "t": 1894717920, "mean": 61.7, "min": 55, "max": 70, "n": 59 }
  ],
  "events": [
    { "t": 1894719900, "kind": "WRIST_OFF" },
    { "t": 1894719960, "kind": "CHARGING_ON" },
    { "t": 1894722000, "kind": "CHARGING_OFF" },
    { "t": 1894722060, "kind": "WRIST_ON" }
  ],
  "battery": [
    { "t": 1894719900, "soc": 22.0, "mv": 3620, "charging": 0 },
    { "t": 1894722000, "soc": 81.5, "mv": 4050, "charging": 1 }
  ],
  "steps": [
    { "day": "2030-01-14", "steps": 8423, "distance_m": 6210.4, "flights": 7 }
  ]
}
"""#
}
