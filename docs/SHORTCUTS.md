# Automatic renewal with Shortcuts

A free Apple ID signs Harbor for seven days. A daily Shortcuts automation
keeps it renewed without opening Harbor. In the app this is Settings ›
Automatic Renewal; this page explains how it works.

## How it works

Harbor puts its own action, **Renew Harbor**, in Shortcuts
(`App/Intents/RenewHarborIntent.swift`). It is there as soon as Harbor is
installed, under Harbor in the action list and as an App Shortcut, so there
is no shortcut to build or download. The automation runs it directly, and
it runs with Harbor in the background:

1. It renews only what expires within two days: Harbor first, then the apps
   it installed. Most days nothing is due and the run ends at once.
2. It retries twice, after 5 and 15 seconds, when the problem is one that
   passes: LocalDevVPN still connecting, the iPhone or a server not
   answering.
3. It checks that each expiry date moved forward. Apple can hand back the
   profile it already issued; that counts as a failure, not a renewal.
4. It reports back to Shortcuts. On success the action's output is the
   result (for example "Nothing needed renewing. Harbor runs until …"). On
   failure the action fails with the reason, so the automation stops and
   Shortcuts shows why.
5. With **Notify When Renewed** on, Harbor also posts a notification when it
   renewed something.

Every run of the action counts toward the status shown in Automatic
Renewal. If none has come for two days, it says the automation isn't
running.

## What iOS allows

- An app can offer actions but not make an automation. The automation
  (Automation › + › Time of Day › Daily › Run Immediately › New Blank
  Automation › Renew Harbor) is created by the person, and the app walks
  them through it.
- Time of Day automations use the iPhone's own time zone.
- Harbor's secrets are readable after the iPhone's first unlock, so the
  action works while the iPhone is locked.
- Renewal needs LocalDevVPN connected. Adding **Set VPN** › **Connect** ›
  **LocalDevVPN** before Renew Harbor takes care of that.

## Older shortcuts

Shortcuts made before Harbor had its own action open
`harbor://x-callback-url/renew` with **Open X-Callback URL**. They still
work, but they bring Harbor to the front, so the iPhone has to be unlocked.
On success Shortcuts receives `status` (`renewed` or `current`), `message`
and `expires` (ISO 8601); on failure Harbor calls `x-error` with an
`errorMessage`.

Harbor only replies to Shortcuts' own reply addresses, of the form
`shortcuts://x-callback-url/ic-success/<id>`, which just resume the shortcut
that is waiting. Any other address, such as `shortcuts://run-shortcut`, is
ignored: Harbor still renews but reports nowhere, so a web page cannot use it
to open an address or run a shortcut of its choosing. Nothing secret is ever
in the reply. Only runs with a reply address count toward the status.

`harbor://renew` and `harbor://refresh` renew without reporting back; when
they fail, Harbor posts a notification.
