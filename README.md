# Introduction

The Twilio SMS plugin for Koha allows patrons to send text messages to Koha and recieve responses in turn.

Actions that can be performed via SMS include:
* List current checkouts ( all overdue, or everything )
* List current fees and fines owed
* List waiting holds
* View list of keywords
* Renewing items ( either specific, all overdue, or everything )
* Change patron's preferred language
* Change SMS phone number

## Configuration

You will need to intput your Account SID, Auth Token and incoming phone number from your Twilio account.
Create a Webhook Auth Token ( basically a password ) in the Webhook Auth Token field, then copy that URL into the Twilio SMS webhook setting.

## Keyword mappings
Each action is triggered by a keyword regular expressions.
These can be overridden in the plugin configuration.
These are the defaults:
* TEST: ^TEST2
* HELP: ^HELP\s*ME
* CHECKOUTS: ^MY\s*ITEMS
* OVERDUES: ^OL
* HOLDS_WAITING: ^HL
* RENEW_ITEM: ^R (\S+)
* RENEW_ALL_ODUE: ^RAO
* RENEW_ALL: ^RA
* ACCOUNTLINES: ^I\s*OWE
* SWITCH_PHONE: ^SWITCH\s*PHONE (\S+)
* LANGUAGES_LIST: ^LANGUAGES
* LANGUAGES_SWITCH: ^LANGUAGE (\S+)

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
