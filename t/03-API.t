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

use Test::More tests => 5;
use Test::NoWarnings;
use Test::Mojo;

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


use C4::Context;
use Koha::Database;
use Koha::Notice::Message;
use Koha::Plugins;

use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::TwilioSMS;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
my $dbh     = C4::Context->dbh;

# The plugin must be installed and enabled before the app starts so its
# routes are merged into the API spec
Koha::Plugins->new->InstallPlugins();
my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioSMS->new;
$plugin->enable;

# This runs outside the transaction below, put the real token back at the end
my $saved_token = $plugin->retrieve_data('WebhookAuthToken');
$plugin->store_data( { WebhookAuthToken => 'sekrit' } );

my $table = $plugin->get_qualified_table_name('messages');

my $t = Test::Mojo->new('Koha::REST::V1');

$schema->storage->txn_begin;

my $patron  = $builder->build_object( { class => 'Koha::Patrons' } );
my $message = Koha::Notice::Message->new(
    {
        borrowernumber         => $patron->id,
        subject                => 'Checkout',
        content                => 'Item due today',
        letter_code            => 'CHECKOUT',
        message_transport_type => 'sms',
        status                 => 'sent',
        time_queued            => \'NOW()',
    }
)->store;

$dbh->do(
    qq{INSERT INTO $table ( twilio_sid, message_id, to_address, twilio_status ) VALUES ( ?, ?, ?, ? )},
    undef, 'SMtestsid', $message->id, '+12085550142', 'queued'
);

my $path = '/api/v1/contrib/twiliosms/message/' . $message->id . '/status';

# The controller warns the callback params for logging, keep the test output clean
local $SIG{__WARN__} = sub { };

subtest 'authentication tests' => sub {
    plan tests => 3;

    $t->post_ok( "$path?token=wrong" => form => { MessageSid => 'SMtestsid', MessageStatus => 'delivered' } )
        ->status_is(401);

    is( $message->discard_changes->status, 'sent', 'message untouched on bad token' );
};

subtest 'unknown message tests' => sub {
    plan tests => 2;

    $t->post_ok(
        '/api/v1/contrib/twiliosms/message/999999999/status?token=sekrit' => form => {
            MessageSid    => 'SMtestsid',
            MessageStatus => 'delivered'
        }
    )->status_is(404);
};

subtest 'non-terminal and delivered statuses keep the message sent' => sub {
    plan tests => 10;

    for my $twilio_status (qw( queued sending sent delivered )) {
        $t->post_ok(
            "$path?token=sekrit" => form => {
                MessageSid    => 'SMtestsid',
                MessageStatus => $twilio_status
            }
        )->status_is(204);
    }

    is( $message->discard_changes->status, 'sent', 'message still sent' );

    my ($twilio_status) = $dbh->selectrow_array(
        qq{SELECT twilio_status FROM $table WHERE twilio_sid = 'SMtestsid'}
    );
    is( $twilio_status, 'delivered', 'delivery status recorded on the plugin table' );
};

subtest 'undelivered marks the message failed' => sub {
    plan tests => 5;

    $t->post_ok(
        "$path?token=sekrit" => form => {
            MessageSid    => 'SMtestsid',
            MessageStatus => 'undelivered',
            ErrorCode     => 30007
        }
    )->status_is(204);

    $message->discard_changes;
    is( $message->status,       'failed',                    'message marked failed' );
    is( $message->failure_code, 'Twilio 30007: undelivered', 'failure code contains the Twilio error' );

    my ( $twilio_status, $error_code ) = $dbh->selectrow_array(
        qq{SELECT twilio_status, error_code FROM $table WHERE twilio_sid = 'SMtestsid'}
    );
    is_deeply(
        [ $twilio_status, $error_code ],
        [ 'undelivered', 30007 ],
        'delivery status and error code recorded on the plugin table'
    );
};

$schema->storage->txn_rollback;

$plugin->store_data( { WebhookAuthToken => $saved_token } ) if defined $saved_token;
