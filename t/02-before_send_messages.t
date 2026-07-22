#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

BEGIN {
    unshift( @INC, '/var/lib/koha/kohadev/plugins' );
    unshift( @INC, '/kohadevbox/koha' );
    unshift( @INC, '/kohadevbox/koha/t/lib' );
}

use Test::More tests => 11;
use Test::NoWarnings;
use Test::MockModule;

# A dev install has the literal placeholder "{VERSION}" as its version, which
# makes every version compare in Koha::Plugins::Base warn. Koha::Plugins loads
# enabled plugins at compile time, so filter that noise before the Koha
# modules load or Test::NoWarnings fails on it.
BEGIN {
    my $previous_warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub {
        return if $_[0] =~ m/Argument "\{VERSION\}" isn't numeric/;
        $previous_warn ? $previous_warn->(@_) : warn @_;
    };
}


use Encode;
use HTTP::Response;
use MIME::Base64;
use URI;

use C4::Context;
use Koha::Database;
use Koha::Notice::Message;
use Koha::Notice::Messages;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::TwilioSMS;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
my $dbh     = C4::Context->dbh;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioSMS->new;
my $table  = $plugin->get_qualified_table_name('messages');

# Make sure the table exists before the transaction begins, DDL would end it
$plugin->_setup();

$schema->storage->txn_begin;

# Neutralize any existing sms messages so they can't interfere with the tests
$dbh->do(
    q{UPDATE message_queue SET status = 'deleted' WHERE message_transport_type = 'sms' AND status IN ('pending','failed')}
);
$dbh->do(qq{DELETE FROM $table});

t::lib::Mocks::mock_preference( 'OPACBaseURL', 'http://opac.test' );

$plugin->store_data(
    {
        EnableOutgoingSMS    => 1,
        AccountSid           => 'ACtest',
        AuthToken            => 'testtoken',
        From                 => '+15005550006',
        SmsServiceAccountSid => q{},
        SmsServiceAuthToken  => q{},
        SmsServiceFrom       => q{},
        WebhookAuthToken     => 'sekrit',
    }
);

# Mock LWP so no requests reach Twilio. Messages.json returns a 201 with a
# sid unless told to fail.
my @requests;
my $send_fails  = 0;
my $sid_counter = 0;
my $mocked_ua   = Test::MockModule->new('LWP::UserAgent');
$mocked_ua->mock(
    request => sub {
        my ( $self, $request ) = @_;
        push @requests, $request;

        return HTTP::Response->new(
            400, 'Bad Request',
            [ 'Content-Type' => 'application/json' ],
            q[{"code": 21211, "message": "Invalid 'To' Phone Number", "status": 400}]
        ) if $send_fails;

        $sid_counter++;
        return HTTP::Response->new(
            201, 'Created',
            [ 'Content-Type' => 'application/json' ],
            qq[{"sid": "SMtest$sid_counter", "status": "queued"}]
        );
    }
);

sub build_patron {
    my ($params) = @_;
    return $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { smsalertnumber => exists $params->{smsalertnumber} ? $params->{smsalertnumber} : '(208) 555-0142' }
        }
    );
}

my $message_counter = 0;
sub build_message {
    my ($params) = @_;
    $message_counter++;
    return Koha::Notice::Message->new(
        {
            borrowernumber         => $params->{patron}->id,
            subject                => 'Checkout',
            content                => $params->{content} // "Item \x{2013} number $message_counter is due today",
            letter_code            => $params->{letter_code} // 'CHECKOUT',
            message_transport_type => 'sms',
            status                 => $params->{status} // 'pending',
            failure_code           => $params->{failure_code},
            time_queued            => \'NOW()',
        }
    )->store;
}

subtest 'disabled or filtered runs do nothing' => sub {
    plan tests => 6;

    my $patron  = build_patron();
    my $message = build_message( { patron => $patron } );

    $plugin->store_data( { EnableOutgoingSMS => 0 } );
    $plugin->before_send_messages( {} );
    is( $message->discard_changes->status, 'pending', 'message untouched when EnableOutgoingSMS is off' );
    is( scalar @requests, 0, 'no requests made when EnableOutgoingSMS is off' );

    $plugin->store_data( { EnableOutgoingSMS => 1 } );

    $plugin->before_send_messages( { type => ['email'] } );
    is( $message->discard_changes->status, 'pending', 'message untouched when limited to another type' );

    $plugin->before_send_messages( { type => 'email' } );
    is( $message->discard_changes->status, 'pending', 'message untouched when limited to another type as a scalar' );

    $plugin->store_data( { AccountSid => q{} } );
    $plugin->before_send_messages( {} );
    is( $message->discard_changes->status, 'pending', 'message untouched without credentials' );
    is( scalar @requests, 0, 'no requests made without credentials' );

    $plugin->store_data( { AccountSid => 'ACtest' } );

    # Consume this message so it can't affect later subtests
    $plugin->before_send_messages( {} );
};

subtest 'happy path' => sub {
    plan tests => 9;

    @requests = ();
    my $patron  = build_patron();
    my $message = build_message( { patron => $patron } );

    $plugin->before_send_messages( { type => ['sms'] } );

    $message->discard_changes;
    is( $message->status,     'sent',           'message marked sent' );
    is( $message->to_address, '(208) 555-0142', 'to_address set to smsalertnumber' );

    my ($send) = grep { $_->uri =~ m/Messages[.]json/ } @requests;
    ok( $send, 'message was posted to Messages.json' );
    ok( $send->header('Authorization'), 'request is authenticated' );

    my $uri = URI->new('http://x');
    $uri->query( $send->content );
    my %form = $uri->query_form;

    is( $form{To},   '+12085550142', 'To is the E.164 formatted number' );
    is( $form{From}, '+15005550006', 'From is the configured number' );
    is(
        $form{Body},
        Encode::encode_utf8( $message->content ),
        'Body is the UTF-8 encoded message content'
    );
    is(
        $form{StatusCallback},
        'http://opac.test/api/v1/contrib/twiliosms/message/' . $message->id . '/status?token=sekrit',
        'StatusCallback points at the plugin status endpoint for this message'
    );

    my ( $sid, $sid_message_id, $sid_to, $sid_status ) = $dbh->selectrow_array(
        qq{SELECT twilio_sid, message_id, to_address, twilio_status FROM $table WHERE message_id = ?},
        undef, $message->id
    );
    is_deeply(
        [ $sid, $sid_message_id, $sid_to, $sid_status ],
        [ "SMtest$sid_counter", $message->id, '+12085550142', 'queued' ],
        'twilio sid recorded for the message'
    );
};

subtest 'SmsService settings are used when set, default to the main settings' => sub {
    plan tests => 6;

    @requests = ();
    $plugin->store_data(
        {
            SmsServiceAccountSid => 'ACsmsservice',
            SmsServiceAuthToken  => 'smsservicetoken',
            SmsServiceFrom       => '+15005559999',
        }
    );

    my $patron = build_patron();
    build_message( { patron => $patron } );
    $plugin->before_send_messages( {} );

    my ($send) = grep { $_->uri =~ m/Messages[.]json/ } @requests;
    like( $send->uri, qr{/Accounts/ACsmsservice/Messages[.]json}, 'SmsServiceAccountSid used in the url' );
    is(
        $send->header('Authorization'),
        'Basic ' . MIME::Base64::encode_base64( 'ACsmsservice:smsservicetoken', q{} ),
        'request authenticated with the SmsService credentials'
    );

    my $uri = URI->new('http://x');
    $uri->query( $send->content );
    my %form = $uri->query_form;
    is( $form{From}, '+15005559999', 'SmsServiceFrom used as the From number' );

    @requests = ();
    $plugin->store_data( { SmsServiceAccountSid => q{}, SmsServiceAuthToken => q{}, SmsServiceFrom => q{} } );

    build_message( { patron => $patron } );
    $plugin->before_send_messages( {} );

    ($send) = grep { $_->uri =~ m/Messages[.]json/ } @requests;
    like( $send->uri, qr{/Accounts/ACtest/Messages[.]json}, 'AccountSid used in the url when SmsService sid unset' );
    is(
        $send->header('Authorization'),
        'Basic ' . MIME::Base64::encode_base64( 'ACtest:testtoken', q{} ),
        'request authenticated with the main credentials when SmsService credentials unset'
    );

    $uri = URI->new('http://x');
    $uri->query( $send->content );
    %form = $uri->query_form;
    is( $form{From}, '+15005550006', 'From used as the From number when SmsServiceFrom unset' );
};

subtest 'missing smsalertnumber' => sub {
    plan tests => 3;

    @requests = ();
    my $patron  = build_patron( { smsalertnumber => undef } );
    my $message = build_message( { patron => $patron } );

    $plugin->before_send_messages( {} );

    $message->discard_changes;
    is( $message->status,       'failed',      'message marked failed' );
    is( $message->failure_code, 'MISSING_SMS', 'failure code matches what Koha itself uses' );
    is( scalar( grep { $_->uri =~ m/Messages[.]json/ } @requests ), 0, 'nothing sent' );
};

subtest 'duplicate messages are not sent' => sub {
    plan tests => 3;

    @requests = ();
    my $patron  = build_patron();
    my $content = "You have checked out Some Item \x{2013} Large Print";

    build_message( { patron => $patron, content => $content, status => 'sent' } );
    my $message = build_message( { patron => $patron, content => $content } );

    $plugin->before_send_messages( {} );

    $message->discard_changes;
    is( $message->status,       'failed',            'duplicate message marked failed' );
    is( $message->failure_code, 'DUPLICATE_MESSAGE', 'failure code matches what Koha itself uses' );
    is( scalar( grep { $_->uri =~ m/Messages[.]json/ } @requests ), 0, 'nothing sent' );
};

subtest 'Twilio send failure' => sub {
    plan tests => 3;

    @requests   = ();
    $send_fails = 1;

    my $patron  = build_patron();
    my $message = build_message( { patron => $patron } );

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $plugin->before_send_messages( {} );
    }

    $message->discard_changes;
    is( $message->status, 'failed', 'message marked failed' );
    is(
        $message->failure_code,
        "Twilio 21211: Invalid 'To' Phone Number",
        'failure code contains the Twilio error'
    );
    ok( ( grep { m/Twilio response indicates failure/ } @warnings ), 'failure was warned about' );

    $send_fails = 0;
};

subtest 'unparseable number falls back to the raw number' => sub {
    plan tests => 2;

    @requests = ();

    my $patron  = build_patron( { smsalertnumber => '5551234' } );
    my $message = build_message( { patron => $patron } );

    $plugin->before_send_messages( {} );

    my ($send) = grep { $_->uri =~ m/Messages[.]json/ } @requests;
    my $uri    = URI->new('http://x');
    $uri->query( $send->content );
    my %form = $uri->query_form;

    is( $form{To}, '5551234', 'raw smsalertnumber used when the number cannot be parsed' );
    is( $message->discard_changes->status, 'sent', 'message still sent' );
};

subtest 'driver load failures from Koha are reset and sent' => sub {
    plan tests => 3;

    @requests = ();
    my $patron = build_patron();

    my $missing = build_message( { patron => $patron, status => 'failed', failure_code => 'SMS_SEND_DRIVER_MISSING' } );
    my $notinstalled = build_message(
        {
            patron       => $patron,
            status       => 'failed',
            failure_code => 'SMS::Send driver TwilioSMSPlugin does not exist, or is not installed'
        }
    );
    my $unrelated = build_message( { patron => $patron, status => 'failed', failure_code => 'NO_NOTES' } );

    $plugin->before_send_messages( {} );

    is( $missing->discard_changes->status,      'sent',   'SMS_SEND_DRIVER_MISSING message reset and sent' );
    is( $notinstalled->discard_changes->status, 'sent',   'driver load error message reset and sent' );
    is( $unrelated->discard_changes->status,    'failed', 'unrelated failed message left alone' );
};

subtest 'letter_code and message_id filters are honored' => sub {
    plan tests => 4;

    @requests = ();
    my $patron   = build_patron();
    my $checkout = build_message( { patron => $patron, letter_code => 'CHECKOUT' } );
    my $hold     = build_message( { patron => $patron, letter_code => 'HOLD' } );

    $plugin->before_send_messages( { letter_code => ['HOLD'] } );
    is( $hold->discard_changes->status,     'sent',    'message matching letter_code filter sent' );
    is( $checkout->discard_changes->status, 'pending', 'message not matching letter_code filter untouched' );

    my $other = build_message( { patron => $patron } );
    $plugin->before_send_messages( { message_id => $checkout->id } );
    is( $checkout->discard_changes->status, 'sent',    'message matching message_id filter sent' );
    is( $other->discard_changes->status,    'pending', 'message not matching message_id filter untouched' );

    # Consume the leftover
    $plugin->before_send_messages( {} );
};

subtest 'long messages are chunked' => sub {
    plan tests => 3;

    @requests = ();
    my $patron  = build_patron();
    my $content = "Line one \x{2013} with more to say\n" x 70;    # ~1960 characters
    my $message = build_message( { patron => $patron, content => $content } );

    $plugin->before_send_messages( {} );

    my @sends = grep { $_->uri =~ m/Messages[.]json/ } @requests;
    is( scalar @sends, 2, 'message was sent in two chunks' );

    my $joined = q{};
    for my $send (@sends) {
        my $uri = URI->new('http://x');
        $uri->query( $send->content );
        my %form = $uri->query_form;
        $joined .= $form{Body};
    }
    is( $joined, Encode::encode_utf8($content), 'chunks reassemble to the full content' );

    my ($sid_count) = $dbh->selectrow_array(
        qq{SELECT COUNT(*) FROM $table WHERE message_id = ?},
        undef, $message->id
    );
    is( $sid_count, 2, 'a twilio sid recorded for each chunk' );
};

$schema->storage->txn_rollback;
