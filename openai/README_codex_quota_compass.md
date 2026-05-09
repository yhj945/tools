# Codex Quota Compass

A Tampermonkey userscript for analyzing Codex quota usage on chatgpt.com. It wraps the original quota calculation logic into an in-page dashboard, renders usage data as tables, caches the latest analysis locally, and supports JSON export.

<!-- AUTO-GENERATED:START -->
## Features

- **In-page Dashboard**: Adds a floating control button and a full-page analysis window on chatgpt.com
- **Quota Window Overview**: Displays primary and secondary rate-limit windows with UTC and local reset times
- **Weekly Quota Estimate**: Uses `used_percent` from the 7-day window to estimate total and remaining weekly credits
- **Usage Summaries**: Shows usage from the last reset, month-to-date, and the recent rolling window
- **Daily Details**: Lists daily credits, USD equivalent, users, threads, turns, and token counts
- **Client Breakdown**: Aggregates usage by client ID for each supported time range
- **Timezone Diagnostics**: Shows browser timezone, UTC offset, backend time, and date bucket boundaries
- **Local Cache**: Stores the latest rendered analysis and export data in `localStorage`
- **JSON Export**: Exports the latest analysis result as a timestamped JSON file
- **Manual Token Fallback**: Supports a temporary local `CONFIG.MANUAL_ACCESS_TOKEN` value if automatic token discovery fails
<!-- AUTO-GENERATED:END -->

## Requirements

- A browser that supports userscripts
- Tampermonkey or a compatible userscript manager
- Logged-in chatgpt.com session
- Access to the Codex usage APIs used by the current ChatGPT web app

## Installation

1. Install Tampermonkey or another compatible userscript manager.
2. Create a new userscript.
3. Copy the contents of `codex-quota-compass.js` into the userscript editor.
4. Save the userscript.
5. Open or refresh a `https://chatgpt.com/` page.

## Quick Start

```text
openai/
└── codex-quota-compass.js      # Tampermonkey userscript
```

After installation:

1. Open `https://chatgpt.com/` and make sure you are logged in.
2. Click the floating dashboard button in the lower-right corner.
3. Select `Run full analysis` from the menu.
4. Wait for the dashboard to fetch usage data and render the tables.
5. Use `Export data JSON` if you need a local copy of the analysis result.

## Menu

<!-- AUTO-GENERATED:START -->
| Action | Description |
|--------|-------------|
| Run full analysis | Fetch usage APIs, calculate quota estimates, and render the dashboard |
| Show / hide window | Toggle the analysis window visibility |
| Export data JSON | Download the latest available analysis data as JSON |
| Clear cache | Remove the cached analysis from `localStorage` |
| Close menu | Hide the floating action menu |
<!-- AUTO-GENERATED:END -->

## Data Sources

<!-- AUTO-GENERATED:START -->
The script reads data from same-origin ChatGPT endpoints:

| Endpoint | Purpose |
|----------|---------|
| `/api/auth/session` | Attempts to locate the current access token from the logged-in browser session |
| `/backend-api/wham/usage` | Reads current rate-limit windows and used percentages |
| `/backend-api/wham/analytics/daily-workspace-usage-counts` | Reads daily usage analytics grouped by day |
<!-- AUTO-GENERATED:END -->

The script uses browser `fetch` with `credentials: include`, so it relies on the current logged-in browser session. It does not send the fetched data to any third-party server.

## Configuration

<!-- AUTO-GENERATED:START -->
Configuration constants are defined inside `buildAnalysisData()`:

| Constant | Default | Description |
|----------|---------|-------------|
| `DATE_BUCKET_MODE` | `utc` | Date bucket mode used for API query boundaries |
| `USD_PER_CREDIT` | `40 / 1000` | Approximate USD conversion used in summary tables |
| `ROLLING_DAYS` | `30` | Number of days used by the rolling usage summary |
| `MANUAL_ACCESS_TOKEN` | empty string | Optional temporary local token fallback |
| `USAGE_PATH` | `/backend-api/wham/usage` | Rate-limit overview endpoint |
| `DAILY_USAGE_PATH` | `/backend-api/wham/analytics/daily-workspace-usage-counts` | Daily analytics endpoint |
<!-- AUTO-GENERATED:END -->

Only edit `MANUAL_ACCESS_TOKEN` on your own computer as a temporary troubleshooting measure. Do not share scripts, screenshots, or logs that contain tokens, cookies, or authorization headers.

## Cached Data

Default browser storage key:

```text
codex-quota-compass:last-analysis
```

The cached object stores:

- Rendered dashboard HTML
- Last analysis timestamp
- Exportable structured analysis data

Use `Clear cache` from the userscript menu to remove it.

## Exported Data

The JSON export file name uses this format:

```text
codex-quota-compass-YYYYMMDD-HHMMSS.json
```

The exported data includes:

- Export timestamp
- Configuration values
- Timezone diagnostics
- Rate-limit window overview
- Weekly quota estimate
- Daily usage details
- Client usage summaries

## Analysis Notes

- `end_date` is an exclusive API boundary.
- Daily analytics are grouped by day and cannot precisely split usage at the hour or minute level.
- The 7-day quota estimate is approximate because it combines daily analytics with integer `used_percent` values.
- If the current day is missing from the daily analytics response, the backend may not have refreshed that data yet or there may be no usage for the day.

## Important Notices and Disclaimer

### Disclaimer

1. **Account Responsibility**: The user is solely responsible for any account suspension, service limitation, or other consequences resulting from the use of this script. **The author assumes no liability.**

2. **No Backdoors**: All data generated by this script is stored **locally only** in the browser. There are **no remote servers, backdoors, or data collection mechanisms**.

3. **Use at Your Own Risk**: This script interacts with ChatGPT web APIs from your logged-in browser session. Improper use may violate service terms or trigger account restrictions. Review the relevant service policies before use.

4. **No Warranty**: This software is provided "as is" without warranty of any kind, express or implied.

### Security Notes

- Browser sessions, cookies, and bearer tokens are sensitive credentials.
- Do not paste access tokens into shared code, issues, screenshots, logs, or chat messages.
- If you use `CONFIG.MANUAL_ACCESS_TOKEN`, clear it after troubleshooting.
- The cache and exported JSON may contain usage metadata. Review files before sharing them.

## License

MIT License

## Credits

This script is based on [BlueSkyXN's original logic](https://gist.github.com/BlueSkyXN/528e810b98affcecca170e6b9d53d7da).
