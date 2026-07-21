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


use File::Temp qw(tempdir);

use C4::Context;
use Koha::Database;

use t::lib::Mocks;

use Koha::Plugin::Com::ByWaterSolutions::TwilioSMS;

my $schema = Koha::Database->new->schema;
my $dbh    = C4::Context->dbh;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioSMS->new;
my $table  = $plugin->get_qualified_table_name('messages');

subtest 'install() tests' => sub {
    plan tests => 4;

    # Run install twice, everything it does must be idempotent.
    # This runs outside of a transaction, the CREATE TABLE would end it.
    $dbh->do(
        q{DELETE FROM plugin_data WHERE plugin_class = ? AND plugin_key = 'WebhookAuthToken'},
        undef, ref $plugin
    );

    $plugin->install();

    my ($table_exists) = $dbh->selectrow_array( q{SHOW TABLES LIKE ?}, undef, $table );
    is( $table_exists, $table, 'plugin messages table created' );

    my $token = $plugin->retrieve_data('WebhookAuthToken');
    like( $token, qr/^[0-9a-f]{64}$/, 'WebhookAuthToken generated' );

    my ($letter_count) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM letter WHERE code LIKE "TWILIO%"});

    $plugin->install();

    my ($letter_count_after) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM letter WHERE code LIKE "TWILIO%"});
    is( $letter_count_after, $letter_count, 'reinstall does not duplicate letters' );

    is( $plugin->retrieve_data('WebhookAuthToken'), $token, 'reinstall does not regenerate WebhookAuthToken' );
};

subtest '_setup() credential import tests' => sub {
    plan tests => 5;

    my %saved = map { $_ => $plugin->retrieve_data($_) } qw(AccountSid AuthToken From);
    $dbh->do(
        q{DELETE FROM plugin_data WHERE plugin_class = ? AND plugin_key IN ('AccountSid','AuthToken','From')},
        undef, ref $plugin
    );

    my $dir = tempdir( CLEANUP => 1 );
    open my $fh, '>', "$dir/Twilio.yaml" or die $!;
    print $fh "accountsid: 'ACyamltest'\nauthtoken: 'yamltoken'\nfrom: '+15005550006'\n";
    close $fh;

    t::lib::Mocks::mock_config( 'sms_send_config', $dir );

    $plugin->_setup();

    is( $plugin->retrieve_data('AccountSid'), 'ACyamltest',   'AccountSid imported from Twilio.yaml' );
    is( $plugin->retrieve_data('AuthToken'),  'yamltoken',    'AuthToken imported from Twilio.yaml' );
    is( $plugin->retrieve_data('From'),       '+15005550006', 'From imported from Twilio.yaml' );

    $plugin->store_data( { AccountSid => 'ACalreadyset' } );
    $plugin->_setup();
    is( $plugin->retrieve_data('AccountSid'), 'ACalreadyset', 'import does not clobber existing AccountSid' );

    t::lib::Mocks::mock_config( 'sms_send_config', '/nonexistent' );
    $plugin->_setup();
    is( $plugin->retrieve_data('AuthToken'), 'yamltoken', '_setup without a config file leaves data alone' );

    for my $key ( keys %saved ) {
        if ( defined $saved{$key} ) {
            $plugin->store_data( { $key => $saved{$key} } );
        } else {
            $dbh->do(
                q{DELETE FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?},
                undef, ref $plugin, $key
            );
        }
    }
};

subtest '_normalize_phone_number() tests' => sub {
    my $cases = [
        [ '(208) 555-0142',   '+12085550142',  'parens and dashes' ],
        [ '208-555-0142',     '+12085550142',  'dashes' ],
        [ '208.555.0142',     '+12085550142',  'dots' ],
        [ '2085550142',       '+12085550142',  'bare 10 digits' ],
        [ '1-208-555-0142',   '+12085550142',  '11 digits with country code' ],
        [ '12085550142',      '+12085550142',  'bare 11 digits' ],
        [ '+12085550142',     '+12085550142',  'already E.164' ],
        [ '+1 (208) 555-0142', '+12085550142', 'international format with formatting' ],
        [ '+44 20 7946 0958', '+442079460958', 'non-NANP international number' ],
        [ '5551234',          '5551234',       '7 digit number passed through untouched' ],
        [ 'not a number',     'not a number',  'garbage passed through untouched' ],
    ];

    plan tests => scalar @$cases;

    for my $case (@$cases) {
        my ( $number, $expected, $description ) = @$case;
        is( $plugin->_normalize_phone_number($number), $expected, $description );
    }
};

subtest 'cronjob_nightly() tests' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    $dbh->do(qq{DELETE FROM $table});
    $dbh->do(
        qq{INSERT INTO $table ( twilio_sid, message_id, twilio_status, created_on ) VALUES
            ( 'SMold', 1, 'delivered', NOW() - INTERVAL 100 DAY ),
            ( 'SMrecent', 2, 'delivered', NOW() - INTERVAL 5 DAY )}
    );

    my $saved_retention = $plugin->retrieve_data('RetentionDays');
    $dbh->do(
        q{DELETE FROM plugin_data WHERE plugin_class = ? AND plugin_key = 'RetentionDays'},
        undef, ref $plugin
    );

    $plugin->cronjob_nightly();
    my ($count) = $dbh->selectrow_array(qq{SELECT COUNT(*) FROM $table});
    is( $count, 1, 'row older than the default 90 days purged' );

    my ($remaining) = $dbh->selectrow_array(qq{SELECT twilio_sid FROM $table});
    is( $remaining, 'SMrecent', 'recent row kept' );

    $plugin->store_data( { RetentionDays => 3 } );
    $plugin->cronjob_nightly();
    ($count) = $dbh->selectrow_array(qq{SELECT COUNT(*) FROM $table});
    is( $count, 0, 'RetentionDays setting is honored' );

    $schema->storage->txn_rollback;
};
