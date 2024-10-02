package Koha::Plugin::Com::ByWaterSolutions::TwilioSMS;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;

use Koha::Account::Lines;
use Koha::Account;
use Koha::DateUtils;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Patron;

use Cwd qw(abs_path);
use Data::Dumper;
use LWP::UserAgent;
use MARC::Record;
use Mojo::JSON qw(decode_json);
use URI::Escape qw(uri_unescape);

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Twilio Interactive SMS',
    author          => 'Kyle M Hall',
    date_authored   => '2023-06-13',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description => 'This plugin enables patrons to send sms messages to Koha and recieve responses via Twilio.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            AccountSid       => $self->retrieve_data('AccountSid'),
            AuthToken        => $self->retrieve_data('AuthToken'),
            From             => $self->retrieve_data('From'),
            KeywordRegExes   => $self->retrieve_data('KeywordRegExes'),
            WebhookAuthToken => $self->retrieve_data('WebhookAuthToken'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                AccountSid       => $cgi->param('AccountSid'),
                AuthToken        => $cgi->param('AuthToken'),
                From             => $cgi->param('From'),
                KeywordRegExes   => $cgi->param('KeywordRegExes'),
                WebhookAuthToken => $cgi->param('WebhookAuthToken'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    my $sql = q{
 INSERT INTO `letter` ( id, module, code, branchcode, name, is_html, title, content, message_transport_type, lang, updated_on )
VALUES      (NULL,
             'circulation',
             'TWILIO_CHECKOUTS_CUR',
             '',
             'Twilio Checkouts - Current',
             0,
             'Twilio Checkouts - Current',
'[% USE KohaDates %]\r\n[%- SET checkouts = borrower.pending_checkouts %]\r\n[% IF checkouts.count %]\r\nYou have the following items checked out:\r\n  [%- FOREACH c IN borrower.pending_checkouts %]\r\n[% c.item.barcode %] : [% c.item.biblio.title %] due [% c.date_due | $KohaDates %]\r\n  [% END %]\r\n[% ELSE %]\r\nYou have nothing checked out.\r\n[% END %]'
             ,
'sms',
'default',
'2023-06-23 11:29:17'),
            (NULL,
             'circulation',
             'TWILIO_TEST',
             '',
             'Twilio Test',
             0,
             'Twilio Test',
'[%- IF borrower %]\r\nYour libray has an account associated with this phone number!\r\n[%- ELSE %]\r\nYour libray has no account associated with this phone number!\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-21 16:39:42'),
            (NULL,
             'circulation',
             'TWILIO_NO_CMD',
             '',
             'Twilio - Command Not Found',
             0,
             'Twilio - Command Not Found',
'I didn\'t understand your command. Send \'HELP ME\' for a list of commands.',
'sms',
'default',
'2023-06-21 16:56:58'),
            (NULL,
             'circulation',
             'TWILIO_HELP',
             '',
             'Twilio - Help',
             0,
             'Twilio - Help',
'You can send the following commands:\r\nMYITEMS - A list of items you have checked out.\r\nOL - A list of overdue items you have checked out.\r\nHL - A list of requested items waiting for pickup.\r\nR <Barcode> - Renew item with the given barcode.\r\nRA - Renew all items.\r\nRO - Renew all overdue items.\r\nI OWE - List outstanding fees and fines.\r\nSWITCH PHONE <phone number> - Switch to the given number for SMS messaging with your library.\r\nLANGUAGE - List available languages for notices.\r\nLANGUAGE <language> - Set your preferred language for notices to the given language.\r\nTEST - Will let you know if you have an account associated with this number or not.\r\nHELP ME - This help text.'
             ,
'sms',
'default',
'2023-06-23 11:28:05'),
            (NULL,
             'circulation',
             'TWILIO_CHECKOUTS_OD',
             '',
             'Twilio Checkouts - Overdue',
             0,
             'Twilio Checkouts - Overdue',
'[%- USE KohaDates %]
[%- SET checkouts = borrower.overdues %]
[%- IF checkouts.count %]
  You have the following overdue items checked out:
  [%- FOREACH c IN borrower.pending_checkouts %]
    [%- IF c.is_overdue %]
        [% c.item.barcode %] : [% c.item.biblio.title %] due [% c.date_due | $KohaDates %]
    [%- END %]
  [%- END %]
[%- ELSE %]
  You have no overdue items checked out.
[%- END %]'
             ,
'sms',
'default',
'2023-06-21 17:26:00'),
            (NULL,
             'circulation',
             'TWILIO_HOLDS_WAITING',
             '',
             'Twilio Holds Waiting',
             0,
             'Twilio Holds Waiting',
'[%- SET has_waiting_holds = 0 %]\r\n[%- SET holds = borrower.holds %]\r\n[%- FOREACH h IN holds %][% IF h.is_waiting%][% SET has_waiting_holds = 1 %][% END %][% END %]\r\n[%- IF has_waiting_holds %]\r\n  You have have the following items waiting:\r\n  [% h.biblio.title %] is waiting at [% h.branch.branchname %]\r\n[%- ELSE %]\r\n  You have no waiting holds.\r\n[% END %] '
             ,
'sms',
'default',
'2023-06-21 17:38:49'),
            (NULL,
             'circulation',
             'TWILIO_RENEW_ONE',
             '',
             'Twilio Renewal - Single Item',
             NULL,
             'Twilio Renewal - Single Item',
'[%- USE KohaDates %]\r\n[%- IF item %]\r\n  [%- IF can_renew %]\r\n    Item has been renewed and is now due on [% renewal_due_date | $KohaDates %]\r\n  [%- ELSE %]\r\n    Unable to renew. Please contact your library for details.\r\n  [%- END %]\r\n[%- ELSE %]\r\n  No item found with that barcode.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-22 11:11:52'),
            (NULL,
             'circulation',
             'TWILIO_RENEW_ALL',
             '',
             'Twilio Renewal - All Items',
             0,
             'Twilio Renewal - All Items',
'[%- USE KohaDates %]\r\n[% FOREACH r IN renewals %]\r\n  [%- IF r.can_renew %]\r\nItem [% r.item.barcode %] has been renewed and is now due on [% r.renewal_due_date | $KohaDates %].\r\n  [%- ELSE %]\r\nItem [% r.item.barcode %] was not renewed.\r\n  [%- END %]\r\n[%- END %]\r\n[%- UNLESS renewals.size %]\r\nYou have no items to renew.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-22 11:32:57'),
            (NULL,
             'circulation',
             'TWILIO_RENEW_ALL_OD',
             '',
             'Twilio Renewal - All Overdues',
             0,
             'Twilio Renewal - All Overdues',
'[%- USE KohaDates %]\r\n[% FOREACH r IN renewals %]\r\n  [%- IF r.can_renew %]\r\nItem [% r.item.barcode %] has been renewed and is now due on [% r.renewal_due_date | $KohaDates %].\r\n  [%- ELSE %]\r\nItem [% r.item.barcode %] was not renewed.\r\n  [%- END %]\r\n[%- END %]\r\n[%- UNLESS renewals.size %]\r\nYou have no overdue items to renew.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-22 11:32:42'),
            (NULL,
             'circulation',
             'TWILIO_ACCOUNTLINES',
             '',
             'Twilio - Account Fees List',
             0,
             'Twilio Accountlines',
'[%- USE Price %]\r\n[%- FOREACH d IN borrower.account.outstanding_debits %]\r\n[% d.amount | $Price %] / [% d.debit_type.description %] / [% d.description %]\r\n[%- END %]\r\n[%- UNLESS borrower.account.outstanding_debits.count %]\r\nYou have no outstanding fees at this time.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-23 11:28:47'),
            (NULL,
             'circulation',
             'TWILIO_SWITCH_PHONE',
             '',
             'Twilio Switch Phone',
             NULL,
             'Twilio Switch Phone',
'[%- IF new_smsalertnumber %]\r\nThe phone number using for SMS messages has now been set to [% new_smsalertnumber %].\r\nIf this was in error, please contact your library for assistance.\r\n[%- ELSE %]\r\nI was unable to update your phone number. Please format the number as a 10 digit number with a country code. For example, the phone number (123) 456-7890 would be +11234567890.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-22 12:06:36'),
            (NULL,
             'circulation',
             'TWILIO_LANGUAGES',
             '',
             'Twilio - Languages - List',
             0,
             'Twilio - Languages - List',
'The following languages are available:\r\n[%- FOREACH l IN languages %]\r\n* [% l.rfc4646_subtag %] - [% l.native_description %]\r\n[%- END %]\r\nTo change your preferred language please reply with the keyword LANGUAGE and the language name or code. For example, both \"LANGUAGE en\" and \"LANGUAGE English\" would set your preferred language to English.'
             ,
'sms',
'default',
'2023-06-23 11:19:26'),
            (NULL,
             'circulation',
             'TWILIO_LANG_SWITCH',
             '',
             'Twilio - Languages - Switch',
             0,
             'Twilio - Languages - Switch',
'[%- IF new_language %]\r\nYour preferred language has been updated from [% old_language.native_description %] to [% new_language.native_description %].\r\n[%- ELSE %]\r\nWe were unable to find a language matching [% requested_language %]. Please reply with LANGUAGES for a list of valid language codes.\r\n[%- END %]'
             ,
'sms',
'default',
'2023-06-23 11:16:45');  
};

    C4::Context->dbh->do($sql);

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'twiliosms';
}

1;
