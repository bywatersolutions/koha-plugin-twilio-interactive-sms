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
use Mojo::JSON qw(decode_json);;
use URI::Escape qw(uri_unescape);

## Here we set our plugin version
our $VERSION = "{VERSION}";
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
    description     => 'This plugin enables patrons to send sms messages to Koha and recieve responses.',
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
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    unless ($cgi->param('save')) {
        my $template = $self->get_template({file => 'configure.tt'});

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            AccountSid               => $self->retrieve_data('AccountSid'),
            AuthToken                => $self->retrieve_data('AuthToken'),
            From                     => $self->retrieve_data('From'),
            WebhookAuthToken         => $self->retrieve_data('WebhookAuthToken'),
        );

        $self->output_html($template->output());
    }
    else {
        $self->store_data({
            AccountSid               => $cgi->param('AccountSid'),
            AuthToken                => $cgi->param('AuthToken'),
            From                     => $cgi->param('From'),
            WebhookAuthToken         => $cgi->param('WebhookAuthToken'),
        });
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    my $sql = q{
INSERT IGNORE INTO `letter`
VALUES      (93,
             'circulation',
             'TWILIO_CHECKOUTS_CUR',
             '',
             'Twilio Checkouts - Current',
             0,
             'Twilio Checkouts - Current',
'[% USE KohaDates %]\r\n[%- SET checkouts = borrower.pending_checkouts %]\r\n[% IF checkouts.count %]\r\n  You have the following items checked out:\r\n  [%- FOREACH c IN borrower.pending_checkouts %]\r\n    [% c.item.barcode %] : [% c.item.biblio.title %] due [% c.date_due | $KohaDates %]\r\n  [% END %]\r\n[% ELSE %]\r\n  You have nothing checked out.\r\n[% END %]'
             ,
'sms',
'default',
'2023-06-21 17:22:04'),
            (94,
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
            (95,
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
            (96,
             'circulation',
             'TWILIO_HELP',
             '',
             'Twilio - Help',
             0,
             'Twilio - Help',
'You can send the following commands:\r\nMYITEMS - A list of items you have checked out.\r\nOL - A list of overdue items you have checked out.\r\nHL - A list of requested items waiting for pickup.\r\nTEST - Will let you know if you have an account associated with this number or not.\r\nHELPME - This help text.'
             ,
'sms',
'default',
'2023-06-21 17:40:10'),
            (97,
             'circulation',
             'TWILIO_CHECKOUTS_OD',
             '',
             'Twilio Checkouts - Overdue',
             0,
             'Twilio Checkouts - Overdue',
'[% USE KohaDates %]\r\n[%- SET checkouts = borrower.overdues %]\r\n[% IF checkouts.count %]\r\n  You have the following overdue items checked out:\r\n  [%- FOREACH c IN borrower.pending_checkouts %]\r\n    [% c.item.barcode %] : [% c.item.biblio.title %] due [% c.date_due | $KohaDates %]\r\n  [% END %]\r\n[% ELSE %]\r\n  You have no overdue items checked out.\r\n[% END %]'
             ,
'sms',
'default',
'2023-06-21 17:26:00'),
            (98,
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
'2023-06-21 17:38:49');  
};

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
    my ( $self ) = @_;
    
    return 'twiliosms';
}

1;
