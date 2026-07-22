# Introduction

The Twilio SMS plugin for Koha sends Koha's SMS notices to patrons via the Twilio API, updates the notice status in Koha from Twilio's delivery callbacks, and allows patrons to send text messages to Koha and receive responses in turn.

## Outgoing SMS notices

When "Enable outgoing SMS notices" is checked in the plugin configuration, the plugin sends Koha's queued sms notices directly via the Twilio Messages API each time process_message_queue.pl runs. This replaces the SMS::Send::Twilio driver, which is unmaintained and fails to send any message containing a character outside Latin-1 ( for example an en dash in a title ) with an error like:

```
Message failed to send with the following error: Can't escape \x{2013}, try uri_escape_utf8() instead at /usr/local/share/perl/5.36.0/WWW/Twilio/API.pm line 116.
```

Each outgoing message includes a status callback URL, so Twilio reports delivery progress back to Koha. If Twilio reports a message failed or undelivered, the notice is marked failed in Koha with the Twilio error code in its failure code ( visible in the patron's Notices tab ), for example `Twilio 30007: undelivered`. Twilio message ids and delivery statuses are kept in a plugin table and purged nightly after the configured retention period.

### Migrating from SMS::Send::Twilio

1. Install this plugin. If an `sms_send/Twilio.yaml` driver config exists on the server, the Account SID, Auth Token, and From number are imported into the plugin configuration automatically.
2. Check "Enable outgoing SMS notices" in the plugin configuration.
3. Set the SMSSendDriver system preference to `TwilioSMSPlugin`. It must *not* be empty ( Koha hides SMS messaging preferences from patrons when it is ), and it must not name an installed SMS::Send driver ( the plugin claims pending messages before Koha's own sending runs, and a resolvable driver could send any message queued in between ).
4. The old `sms_send/Twilio.yaml` file can be removed.

Notes:
* The status callback URL is built from the OPACBaseURL system preference: `<OPACBaseURL>/api/v1/contrib/twiliosms/message/<id>/status`. If the OPAC sits behind Cloudflare or another WAF, add a rule allowing POSTs to `/api/v1/contrib/twiliosms/` or the callbacks will be blocked.
* Outgoing SMS notices can be sent from their own Twilio account and phone number by setting the SMS Service Account SID, SMS Service Auth Token, and SMS Service Phone Number. All three default to the main Account SID, Auth Token, and From Phone Number if empty.
* Patron phone numbers are normalized to E.164 format before sending. Numbers already in international format keep their country code, bare 10 and 11 digit NANP numbers get a +1 prefix, and anything else is passed to Twilio as-is for validation.

## Interactive SMS

Patrons can text keywords to your Twilio number to perform actions in Koha.

Actions that can be performed via SMS include:
* List current checkouts ( all overdue, or everything )
* List current fees and fines owed
* List waiting holds
* View list of keywords
* Renewing items ( either specific, all overdue, or everything )
* Change patron's preferred language
* Change SMS phone number

This feature is dormant unless you configure the incoming webhook in Twilio as described below.

## Configuration

You will need to input your Account SID, Auth Token and incoming phone number from your Twilio account.
A Webhook Auth Token ( basically a password ) is generated at install time; for interactive SMS, copy the webhook URL shown in the configuration screen into the Twilio SMS webhook setting. The same token authenticates the delivery status callbacks for outgoing notices, which require no Twilio console configuration.

## Keyword mappings
Each action is triggered by a keyword regular expressions.
These can be overridden in the plugin configuration.
These are the defaults:
```yaml
TEST: ^TEST
HELP: ^HELP\s*ME
CHECKOUTS: ^MY\s*ITEMS
OVERDUES: ^OL
HOLDS_WAITING: ^HL
RENEW_ITEM: ^R (\S+)
RENEW_ALL_ODUE: ^RAO
RENEW_ALL: ^RA
ACCOUNTLINES: ^I\s*OWE
SWITCH_PHONE: ^SWITCH\s*PHONE (\S+)
LANGUAGES_LIST: ^LANGUAGES
LANGUAGES_SWITCH: ^LANGUAGE (\S+)
```

## Notices

Each keyword is related to one or more notice templates.
They are:
* TEST: TWILIO_TEST
* HELP: TWILIO_HELP
* CHECKOUTS: TWILIO_CHECKOUTS_CUR
* OVERDUES: TWILIO_CHECKOUTS_OD
* HOLDS_WAITING: TWILIO_HOLDS_WAITING
* RENEW_ITEM: TWILIO_RENEW_ONE
* RENEW_ALL: TWILIO_RENEW_ALL
* RENEW_ALL_ODUE: TWILIO_RENEW_ALL_OD
* ACCOUNTLINES: TWILIO_ACCOUNTLINES
* SWITCH_PHONE: TWILIO_SWITCH_PHONE
* LANGUAGES_LIST: TWILIO_LANGUAGES
* LANGUAGES_SWITCH: TWILIO_LANG_SWITCH
* No matching keyword found in message: TWILIO_NO_CMD

### Notice template variables

Unless otherwise specified, each template only has access to the `borrower` variable
and can access all needed data from that.

#### Exceptions
TWILIO_RENEW_ONE:
`item`: The item to renew
`can_renew`: Indicates of the item was renewable
`cannot_renew_reason`: Reason code for why the renewal failed
`renewal_due_date`: The date the renewed item is now due on

RENEW_ALL/RENEW_ALL_ODUE:
`renewals`: A list of hashes containing the data described above for TWILIO_RENEW_ONE

SWITCH_PHONE:
`new_smsalertnumber`: The new sms alert number the patron was switched to

LANGUAGES_LIST:
`languages`: List of available languages

LANGUAGES_SWITCH:
`requested_language`: Language the patron requested to be switched to
`new_language`: The language the patron was switched to
`old_language`: The language the patron was switched from



# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-kitchen-sink/releases) you can download the relevant *.kpz file
