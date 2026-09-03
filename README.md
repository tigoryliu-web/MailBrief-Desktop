# MailBrief Desktop

A native macOS desktop app that organizes Gmail, Outlook, and other IMAP inboxes in a desktop widget. It turns incoming messages into concise summaries and actionable checklist items.

## Features

- A borderless desktop window that sits at the wallpaper level, supports dragging and resizing, and remembers its position.
- Up to five dynamic mailbox sections with controls to add, rename, reorder, disconnect, and remove accounts from the Mac.
- Read-only OAuth access for Gmail and personal Outlook accounts. Other providers, including iCloud, Yahoo, QQ Mail, and NetEase Mail, can connect through TLS IMAP with app-specific passwords.
- Collapsible mailbox sections and Urgent, Important, and Normal priority sorting.
- AI-generated message categories: Action Required, School, Finance, Shopping, Travel, Newsletter, Spam / Low Priority, or Other.
- Aggressive promotion filtering. Gmail Promotions messages and mail with explicit bulk-marketing markers are removed before any OpenAI request; remaining messages are classified by AI. Filtered promotions never enter summaries, notifications, or persisted local data.
- Reversible completion controls. Completed items are removed after the next successful refresh.
- Manual refresh and per-mailbox retry, plus up to five optional daily scheduled refresh times.
- Missed scheduled refreshes are not replayed. Scheduled runs are skipped when every connected mailbox refreshed successfully within the previous 15 minutes, and failed scheduled runs are not retried automatically.
- Scheduled refresh notifications appear only for newly detected urgent items, avoiding routine success and individual mailbox-failure alerts.
- Menu bar integration, a settings window, and an optional launch-at-login setting.
- Structured summaries through the OpenAI Responses API, with the API key stored in the macOS Keychain.
- A Simplified Chinese / English language switch in Settings. New summaries follow the current app language; existing summaries are not reclassified.
- Text extraction from PDF, DOCX, plain-text, and OCR-compatible image attachments, with a 20 MB limit.
- Local JSON state persistence and grouped notifications.
- Read-only synchronization through the Gmail API and Microsoft Graph. OAuth tokens and IMAP app-specific passwords are stored in the macOS Keychain.
- Summaries containing a clear date can be added to the default Apple Calendar after user confirmation. The app checks for local scheduling conflicts and duplicate events before adding anything.
- Demo mode and automated tests for core rules.

## Build

Xcode 26 or a compatible version is required.

```sh
cd /path/to/MailBrief-Desktop
./scripts/build_app.sh
```

Local builds use ad hoc signing by default. To use your own Apple Development certificate, set the signing identity only in your local terminal. Do not write it into the source code.

```sh
MAIL_BRIEF_SIGNING_IDENTITY="Apple Development: your-account@example.com (TEAMID)" ./scripts/build_app.sh
```

The generated app and archive are written to the `dist/` directory.

## Demo Mode

Demo mode uses built-in sample data. It does not read a mailbox or call the OpenAI API.

```sh
open dist/*.app --args --demo
```

## Privacy

- Gmail and Outlook request read-only mail permissions. IMAP connections use TLS and read-only commands to access the inbox.
- Apple Calendar data is read locally only after the user chooses to add an event. It is used for conflict detection and is never sent to a cloud service.
- API keys, OAuth tokens, and IMAP app-specific passwords remain in the macOS Keychain.
- Message bodies and attachments exist only while they are being processed and are not written to the persisted summary file.
- OpenAI requests use `store: false`. Account passwords and OAuth tokens are never sent to the model.
- This repository contains no API keys, OAuth client credentials, mailbox accounts, or app-specific passwords. Every user must configure those values on their own device.
