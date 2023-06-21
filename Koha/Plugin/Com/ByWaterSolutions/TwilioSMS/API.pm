package Koha::Plugin::Com::ByWaterSolutions::TwilioSMS::API;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;
use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);

=head1 API

=head2 Class Methods

=head3 Method to handle incoming SMS webhooks from Twilio

=cut

sub webhook {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn "PARAMS: " . Data::Dumper::Dumper( $c->req->params->to_hash );
    my $To       = $params->{From};   # Weird but less confusing in the long run
    my $incoming = $params->{Body};   # We are respnding *To* the *From* number

    my $token = $c->validation->param('token');

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioSMS->new();

    my $WebhookAuthToken = $plugin->retrieve_data('WebhookAuthToken');
    my $AccountSid       = $plugin->retrieve_data('AccountSid');
    my $AuthToken        = $plugin->retrieve_data('AuthToken');
    my $From             = $plugin->retrieve_data('From');

    unless ( $token eq $WebhookAuthToken ) {
        return $c->render(
            status  => 401,
            openapi => { error => "Invalid token" }
        );
    }

    my $body = $params->{Body};
    my $from = $params->{From};

    my $patron;

    # Look for exact match first
    unless ( $patron = Koha::Patrons->find( { smsalertnumber => $from } ) ) {

        # Look for a match without the country code
        $from =~ s/^\+1//g;    # Remove country code ( hard coded to USA atm )
        $patron = Koha::Patrons->find( { smsalertnumber => $from } );
    }

    # TODO: move this to a TWILIO_NO_CMD template
    my $outgoing =
      "I didn't understand your command. Send 'HELP' for a list of commands";

    my $code = "TWILIO_NO_CMD";
    my $lang = $patron ? $patron->lang : "default";

    my $tables = {};
    $tables->{borrowers} = $patron->id if $patron;

    if ( !$patron || $body =~ m/^TEST/i ) {
        $code = "TWILIO_TEST";
    }
    elsif ( $body =~ m/^HELP\s*ME/i ) {
        $code = "TWILIO_HELP";
    }
    else {
        $code = "TWILIO_NO_CMD";
    }

    my $template =
      Koha::Notice::Templates->find( { code => $code, lang => $lang } );
    my $template_content = $template->content;
    warn "TABLES: " . Data::Dumper::Dumper($tables);
    my $letter = C4::Letters::GetPreparedLetter(
        module      => 'circulation',
        letter_code => $code,
        lang        => $lang,
        tables      => $tables,
        objects     => {
            nothing => undef # Placeholder in case $tables is empty
        },
        message_transport_type => 'sms'
    );
    warn "LETTER: " . Data::Dumper::Dumper($letter);
    $outgoing = $letter->{content};

    warn "OUTGOING: $outgoing";

    my $ua = LWP::UserAgent->new;
    my $url =
      "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Messages.json";
    my $request = POST $url,
      [
        From => $From,
        To   => $To,
        Body => $outgoing,
      ];
    $request->authorization_basic( $AccountSid, $AuthToken );
    my $response = $ua->request($request);

    if ( $response->is_success ) {
        warn "RESPONSE: " . $response->decoded_content;
    }
    else {
        warn "Twilio response indicates failure: " . $response->status_line;
    }

    return $c->render(
        status  => 200,
        openapi => { bothered => Mojo::JSON->true }
    );
}

1;
