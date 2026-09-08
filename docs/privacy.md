# Privacy and local data

Keel sends no telemetry or automatic crash reports to its developer. This describes the current pre-release app, not the privacy practices of websites you visit.

## What stays on your Mac

Keel stores browsing History, queued URLs, preferences, download records, and recovery checkpoints locally. WebKit stores website data such as cookies and local storage in Keel's browser profile. Imported Home photos are copies, so removing the original photo does not remove Keel's copy.

History persists until you delete it. Queue entries expire according to your selected retention period. Expiring a queue entry does not erase a past visit from History. Download records and downloaded files are separate things.

Local data is not the same as encrypted data. Keel has no private browsing mode and makes no claim to hide browsing from another person with access to your Mac, backups, or account.

## What uses the network

- Opening a page sends requests to that website and the services it loads.
- Submitting a search sends the query to your selected provider. The default is Google; Settings also offers DuckDuckGo, Kagi, and a custom URL template.
- The address field can request a host's `/favicon.ico` after you type a complete hostname and pause. This request can happen before you open the page. Keel's favicon transport does not attach browser cookies and does not follow redirects.
- Queuing a URL does not load its website in the background.

Keel is not a VPN, an anonymity tool, or a built-in ad and tracker blocker.

## Diagnostics

Keel keeps bounded local diagnostics. They may contain hostnames, event types, timings, results, and error codes. They exclude full URLs, page contents, cookies, and form values. Settings lets you export or delete diagnostics. Keel does not automatically send an export anywhere; review it before sharing it.

## Deleting data

Use History to remove visits and Home to remove queued destinations. Settings can delete diagnostics and remove imported photos. Deleting a download record does not delete the downloaded file; manage files in Finder.

Removing `Keel.app` does not erase its sandboxed profile or files saved to Downloads. Keel does not yet provide a single control that erases every category of browser data. A complete, verified profile-removal guide is part of the public-release preparation.

Do not attach your browser database, website storage, personal screenshots, or a complete profile to a public bug report.
