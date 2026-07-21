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
use Koha::Notice::Messages;
use Koha::Patron::Categories;
use Koha::Patron;
use Koha::Patrons;

use Cwd qw(abs_path);
use Data::Dumper;
use Digest::SHA qw(sha256_hex);
use Encode;
use File::Spec;
use HTTP::Request::Common;
use LWP::UserAgent;
use MARC::Record;
use Mojo::JSON  qw(decode_json);
use URI::Escape qw(uri_unescape);
use YAML::XS;

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
    description     => 'This plugin enables patrons to send sms messages to Koha and recieve responses via Twilio.',
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

sub before_send_messages {
    my ( $self, $params ) = @_;

    return unless $self->retrieve_data('EnableOutgoingSMS');

    my $type        = $params->{type};
    my $letter_code = $params->{letter_code};
    my $where       = $params->{where};
    my $message_id  = $params->{message_id};

    # If a type limit is passed in, only run if the type is "sms"
    return
           if ref($type) eq 'ARRAY'
        && scalar @$type > 0
        && !grep( /^sms$/, @$type );
    return if defined($type) && ref($type) eq q{} && $type ne q{} && $type ne 'sms';

    # If this version of Koha sends an arrayref, check the length of it and set the var to false if it has no elements
    $letter_code = undef if ref($letter_code) eq 'ARRAY' && scalar @$letter_code == 0;

    my $AccountSid       = $self->retrieve_data('AccountSid');
    my $AuthToken        = $self->retrieve_data('AuthToken');
    my $From             = $self->retrieve_data('From');
    my $WebhookAuthToken = $self->retrieve_data('WebhookAuthToken');

    # Outgoing SMS notices can be sent from their own Twilio account,
    # defaulting to the account the interactive features use
    my $SmsServiceAccountSid = $self->retrieve_data('SmsServiceAccountSid') || $AccountSid;
    my $SmsServiceAuthToken  = $self->retrieve_data('SmsServiceAuthToken')  || $AuthToken;

    return unless $SmsServiceAccountSid && $SmsServiceAuthToken && $From;

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('messages');

    # Koha's own message queue processing runs after this hook and can grab any
    # sms message queued in the moment between our search below and its own.
    # With SMSSendDriver set to a placeholder those messages fail with a driver
    # load error, so reset them to pending and they are picked up on this run.
    $dbh->do(
        q{
        UPDATE message_queue
        SET status = 'pending',
            failure_code = NULL
        WHERE status = 'failed'
          AND message_transport_type = 'sms'
          AND ( failure_code = 'SMS_SEND_DRIVER_MISSING'
             OR failure_code LIKE '%does not exist, or is not installed%' )
    }
    );

    my $parameters = { status => 'pending', message_transport_type => 'sms' };
    $parameters->{letter_code} = $letter_code if $letter_code;
    $parameters->{message_id}  = $message_id  if $message_id;
    my $messages = Koha::Notice::Messages->search($parameters);
    $messages = $messages->search( \$where ) if $where;

    my $OPACBaseURL = C4::Context->preference('OPACBaseURL');

    my $ua = LWP::UserAgent->new;

    while ( my $m = $messages->next ) {

        # Claim the message before Koha's own message queue processing searches for pending messages
        $m->status('sent');
        $m->update();

        my $patron         = Koha::Patrons->find( $m->borrowernumber );
        my $smsalertnumber = $patron ? $patron->smsalertnumber : undef;

        unless ($smsalertnumber) {
            $m->status('failed');
            $m->failure_code('MISSING_SMS');
            $m->update();
            next;
        }

        $m->to_address($smsalertnumber);
        $m->update();

        # The same duplicate check Koha's _send_message_by_sms does, excluding
        # this message which we have already marked sent to claim it
        my $is_duplicate = $dbh->selectrow_array(
            q{
            SELECT COUNT(*)
            FROM message_queue
            WHERE message_transport_type = ?
            AND borrowernumber = ?
            AND letter_code = ?
            AND CAST(updated_on AS date) = CAST(NOW() AS date)
            AND status="sent"
            AND content = ?
            AND message_id != ?
        }, {}, 'sms', $m->borrowernumber, $m->letter_code, $m->content, $m->id
        );
        if ($is_duplicate) {
            $m->status('failed');
            $m->failure_code('DUPLICATE_MESSAGE');
            $m->update();
            next;
        }

        my $to = $self->_normalize_phone_number($smsalertnumber);

        my $message_id = $m->id;
        my $status_callback_url =
            "$OPACBaseURL/api/v1/contrib/twiliosms/message/$message_id/status?token=$WebhookAuthToken";

        # Twilio cannot auto-split messages over 1600 characters, so we need to split
        # our message into 1600 character chunks and send each one separately.
        # Twilio should then split those messages into 160 character chunks as well
        my @chunks = $m->content =~ /(.{1,1600})/sg;

        my $url = "https://api.twilio.com/2010-04-01/Accounts/$SmsServiceAccountSid/Messages.json";

        for my $chunk (@chunks) {
            my @form = (
                To             => $to,
                From           => $From,
                Body           => Encode::encode_utf8($chunk),
                StatusCallback => $status_callback_url,
            );

            my $request = POST $url, \@form;
            $request->authorization_basic( $SmsServiceAccountSid, $SmsServiceAuthToken );
            my $response = $ua->request($request);

            my $data = eval { decode_json( $response->decoded_content ) };

            if ( $response->is_success ) {
                $dbh->do(
                    qq{INSERT INTO $table ( twilio_sid, message_id, to_address, twilio_status ) VALUES ( ?, ?, ?, ? )},
                    undef, $data->{sid}, $m->id, $to, $data->{status}
                ) if $data && $data->{sid};
            } else {
                warn "Twilio response indicates failure: " . $response->status_line;
                my $failure_code =
                    $data && $data->{code}
                    ? "Twilio " . $data->{code} . ": " . $data->{message}
                    : "Twilio: " . $response->status_line;
                $m->status('failed');
                $m->failure_code($failure_code);
                $m->update();
                last;
            }
        }
    }
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            AccountSid           => $self->retrieve_data('AccountSid'),
            AuthToken            => $self->retrieve_data('AuthToken'),
            From                 => $self->retrieve_data('From'),
            SmsServiceAccountSid => $self->retrieve_data('SmsServiceAccountSid'),
            SmsServiceAuthToken  => $self->retrieve_data('SmsServiceAuthToken'),
            EnableOutgoingSMS    => $self->retrieve_data('EnableOutgoingSMS'),
            RetentionDays        => $self->retrieve_data('RetentionDays'),
            KeywordRegExes       => $self->retrieve_data('KeywordRegExes'),
            WebhookAuthToken     => $self->retrieve_data('WebhookAuthToken'),
        );

        $self->output_html( $template->output() );
    } else {
        $self->store_data(
            {
                AccountSid           => $cgi->param('AccountSid'),
                AuthToken            => $cgi->param('AuthToken'),
                From                 => $cgi->param('From'),
                SmsServiceAccountSid => $cgi->param('SmsServiceAccountSid'),
                SmsServiceAuthToken  => $cgi->param('SmsServiceAuthToken'),
                EnableOutgoingSMS    => $cgi->param('EnableOutgoingSMS') ? 1 : 0,
                RetentionDays        => $cgi->param('RetentionDays'),
                KeywordRegExes       => $cgi->param('KeywordRegExes'),
                WebhookAuthToken     => $cgi->param('WebhookAuthToken'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    $self->_setup();

    my $sql = q{
 INSERT IGNORE INTO `letter` ( id, module, code, branchcode, name, is_html, title, content, message_transport_type, lang, updated_on )
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

    $self->_setup();

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub cronjob_nightly {
    my ($self) = @_;

    my $retention_days = $self->retrieve_data('RetentionDays') || 90;
    my $table          = $self->get_qualified_table_name('messages');

    C4::Context->dbh->do(
        qq{DELETE FROM $table WHERE created_on < NOW() - INTERVAL ? DAY},
        undef, $retention_days
    );
}

sub _normalize_phone_number {
    my ( $self, $number ) = @_;

    # Keep a leading + but strip all other formatting
    my $has_plus = $number =~ m/^\s*\+/;
    my $digits   = $number;
    $digits =~ s/[^0-9]//g;

    # Already in international format
    return "+$digits" if $has_plus && $digits;

    # NANP numbers are 10 digits, or 11 digits with a leading country code of 1
    return "+1$digits" if length($digits) == 10;
    return "+$digits"  if length($digits) == 11 && substr( $digits, 0, 1 ) eq '1';

    # Anything else is passed through untouched for Twilio to validate
    return $number;
}

sub _setup {
    my ($self) = @_;

    my $table = $self->get_qualified_table_name('messages');

    C4::Context->dbh->do(
        qq{
        CREATE TABLE IF NOT EXISTS $table (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `twilio_sid` VARCHAR(34) NOT NULL,
            `message_id` INT(11) NULL DEFAULT NULL,
            `to_address` VARCHAR(64) NULL DEFAULT NULL,
            `twilio_status` VARCHAR(24) NULL DEFAULT NULL,
            `error_code` INT(11) NULL DEFAULT NULL,
            `created_on` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_on` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `twilio_sid` (`twilio_sid`),
            KEY `message_id` (`message_id`),
            KEY `created_on` (`created_on`)
        ) ENGINE = INNODB;
    }
    );

    # Import credentials from the SMS::Send::Twilio driver config this plugin replaces
    my $sms_send_config = C4::Context->config('sms_send_config');
    if ($sms_send_config) {
        my $conf_file = File::Spec->catfile( $sms_send_config, 'Twilio.yaml' );
        if ( -f $conf_file ) {
            my $conf = eval { YAML::XS::LoadFile($conf_file) };
            if ($conf) {
                $self->store_data( { AccountSid => $conf->{accountsid} } )
                    if $conf->{accountsid} && !$self->retrieve_data('AccountSid');
                $self->store_data( { AuthToken => $conf->{authtoken} } )
                    if $conf->{authtoken} && !$self->retrieve_data('AuthToken');
                $self->store_data( { From => $conf->{from} } )
                    if $conf->{from} && !$self->retrieve_data('From');
            }
        }
    }

    $self->store_data( { WebhookAuthToken => sha256_hex( time . $$ . rand ) } )
        unless $self->retrieve_data('WebhookAuthToken');

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
